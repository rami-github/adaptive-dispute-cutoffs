pragma solidity >=0.4.21 <0.7.0;
pragma experimental ABIEncoderV2;

import "./RLPReader.sol";
import "./ABDKMathQuad.sol";
import "./DecodeLib.sol";
import "./TreeLib.sol";

library VerifierLib {
  uint256 constant RANGE_MOD = 2 ** 128;
  bytes32 constant ZERO_BYTES = bytes32(0);
  uint256 constant MAX_BLOCKS = 256;
  uint256 constant ALPHA_DENOM = 2 ** 20;
  int256 constant ERR_PROB_EXPON = -80;

  struct BlocksDB {
    bytes32[] commitments;
    uint256[] blockRanges;
  }

  function init(
    BlocksDB storage self
  )
    public
  {
    uint256 numEntries = self.commitments.length;
    require(numEntries == 0);
    self.commitments.push(ZERO_BYTES);
    self.blockRanges.push(block.number + block.number * RANGE_MOD);
  }

  function saveBlocks(
    BlocksDB storage self
  )
    public
  {
    uint256 numEntries = self.blockRanges.length;
    require(numEntries > 0);

    uint256 startingBlockNum = block.number >= MAX_BLOCKS ? block.number - MAX_BLOCKS : 0;
    uint256 lastBlockStart = self.blockRanges[numEntries - 1] % RANGE_MOD;
    uint256 lastBlockEnd = self.blockRanges[numEntries - 1] / RANGE_MOD;

    if (startingBlockNum <= lastBlockStart) {
      startingBlockNum = lastBlockStart;
      self.commitments[numEntries - 1] = calculateBlockCommitment(startingBlockNum);
    } else {
      if (startingBlockNum <= lastBlockEnd) {
        startingBlockNum = lastBlockEnd;
      }
      self.commitments.push(calculateBlockCommitment(startingBlockNum));
      self.blockRanges.push(uint256(startingBlockNum) + (block.number * RANGE_MOD));
    }
    require(self.commitments.length == self.blockRanges.length, 'BlocksDB Length mismatch.');
  }

  function calculateBlockCommitment(
    uint256 startingBlock
  )
    public
    view
    returns (bytes32)
  {
    int64 minHeight = -1;
    uint64 maxHeight = 0;
    bytes32[32] memory treeRoots;
    for (uint256 blockNum = startingBlock; blockNum < block.number; blockNum++) {
      bytes32 blockHash = blockhash(blockNum);
      require(blockHash != ZERO_BYTES, 'Hash out of lookup range.');
      (minHeight, maxHeight) = TreeLib.bubble_up(treeRoots, maxHeight, 0, blockHash);
    }
    while (minHeight != int64(treeRoots.length) -1) {
      (minHeight, maxHeight) = TreeLib.bubble_up(treeRoots, maxHeight, uint64(minHeight), ZERO_BYTES);
    }
    return treeRoots[treeRoots.length - 1];
  }

  function maxCGas(
    uint256 pGas,
    uint256 disputeGasCost,
    uint256 blocks
  )
    public
    pure
    returns (uint256)
  {
    require(disputeGasCost > 0);
    uint256 incompleteSegments = pGas / (disputeGasCost - 1);
    uint256 remainder = pGas % (disputeGasCost - 1);
    uint256 m1 = blocks * (incompleteSegments / blocks - 1);
    uint256 m2 = incompleteSegments % blocks;
    if (incompleteSegments < blocks) {
      return 0;
    } else if (remainder == 0) {
      return m1 + m2;
    } else {
      return m1 + m2 + 1;
    }
  }

  function verifyPGas(
    uint256 n,
    uint256 pGasClaimed,
    uint256 alphaClaimed,
    uint256 confidence
  )
    public
    pure
    returns (uint256)
  {
    require(alphaClaimed < ALPHA_DENOM);
    bytes16 alpha = ABDKMathQuad.div(ABDKMathQuad.fromUInt(alphaClaimed), ABDKMathQuad.fromUInt(ALPHA_DENOM));
    bytes16 alpha_n = ABDKMathQuad.fromUInt(1);
    for (uint256 i = 0; i < n; i++) {
      alpha_n = ABDKMathQuad.mul(alpha, alpha_n);
    }
    require(confidence < 100);
    bytes16 lambda = ABDKMathQuad.pow_2(ABDKMathQuad.fromInt(ERR_PROB_EXPON));
    require(ABDKMathQuad.cmp(alpha_n, lambda) < 0);
    return pGasClaimed * alphaClaimed / ALPHA_DENOM;
  }

  function verifyBlockGas(
    bytes memory blockHeader,
    uint256 unusedGas
  )
    internal
    returns (bool)
  {
    (uint256 blockGasLimit, uint256 blockGasUsage) = DecodeLib.decodeBlockGasUsed(blockHeader);
    return unusedGas == (blockGasLimit - blockGasUsage);
  }

  function verifyTransactionGas(
    bytes memory blockHeader,
    uint256 transactionNumber,
    bytes[2] memory transactionNumberKey,
    uint256 maxGasPrice,
    uint256 gasClaimed,
    bytes[] memory txInclusionProof,
    bytes[] memory receiptInclusionProof,
    bytes[] memory priorReceiptInclusionProof
  )
    internal
    returns (bool)
  {
    // verify transaction gas
    bytes32[2] memory roots = DecodeLib.decodeTxReceiptRoots(blockHeader);
    // read from transactionRoot
    bytes memory transaction = TreeLib.readTrieValue(
      roots[0],
      transactionNumber,
      transactionNumberKey[0],
      txInclusionProof);
      // txGasPrice <= maxGasPrice
    if (DecodeLib.decodeGasPrice(transaction) > maxGasPrice) {
      return false;
    }
    // read from receiptsRoot
    bytes memory receipt = TreeLib.readTrieValue(
      roots[1],
      transactionNumber,
      transactionNumberKey[0],
      receiptInclusionProof);
    uint256 gasUsed = DecodeLib.decodeGasUsed(receipt);
    if (transactionNumber > 0) {
      bytes memory receiptPrior = TreeLib.readTrieValue(
        roots[1],
        transactionNumber - 1,
        transactionNumberKey[1],
        priorReceiptInclusionProof);
      gasUsed = gasUsed - DecodeLib.decodeGasUsed(receiptPrior);
    }
    return gasClaimed == gasUsed;
  }

  function verifyBlockInclusion(
    BlocksDB storage self,
    bytes memory blockHeader,
    uint256 blockNumber,
    uint256 commitmentNumber,
    bytes32[] memory blockInclusionProof
  )
    internal
    returns (bool)
  {
    bytes32 blockHash = keccak256(blockHeader);
    return TreeLib.verifyTreeMembership(
      self.commitments[commitmentNumber],
      blockHash,
      blockNumber - (self.blockRanges[commitmentNumber] % RANGE_MOD),
      blockInclusionProof);
  }

  function verifyGasPosition(
    bytes32 pGasCommitment,
    uint256 pGasClaimed,
    uint256 nonce,
    uint256 prefixSum,
    uint256 leafSum
  )
    internal
    returns (bool)
  {
    uint256 g = uint256(keccak256(abi.encodePacked(pGasCommitment, pGasClaimed, nonce))) % pGasClaimed;
    return prefixSum < g && g <= prefixSum + leafSum;
  }

  function verifyCGas(
    BlocksDB storage self,
    uint256[7] memory subStack,
    // uint256 maxGasPrice,
    // uint256 disputeGasCost,
    // uint256 startingBlockNum,
    // uint256 endingBlockNum,
    // uint256 pGasClaimed,
    // uint256 alphaClaimed,
    // uint256 confidence,
    bytes32 pGasCommitment,
    bytes32[][] memory msmOpenings,
    bytes[] memory blockHeaders,
    uint256[] memory blockInclusionCommitments,
    bytes32[][] memory blockInclusionProofs,
    bytes[][] memory txInclusionProofs,
    bytes[] memory txNumKeys
  )
    public
    returns (uint256 cGasVerified)
  {
    for (uint256 i = 0; i < msmOpenings.length; i++) {
      uint256[3] memory prefixLeafVal = TreeLib.openMSMCommitment(
        pGasCommitment,
        subStack[4], // pGasClaimed
        subStack[2], // startingBlockNum
        subStack[3], // endingBlockNum
        msmOpenings[i]);
      require(verifyGasPosition(
        pGasCommitment,
        subStack[4], // pGasClaimed
        i,
        prefixLeafVal[0], // prefixSum
        prefixLeafVal[1] // leafSum
      ), 'g out of range');
      require(verifyBlockInclusion(
        self,
        blockHeaders[i],
        prefixLeafVal[2] / RANGE_MOD, // value / RANGE_MOD = blockNumber
        blockInclusionCommitments[i],
        blockInclusionProofs[i]), 'bad block inclusion proof');
      uint256 txNum = prefixLeafVal[2] % RANGE_MOD; // value % RANGE_MOD = txNum
      if (txNum == RANGE_MOD - 1) {
        require(verifyBlockGas(
          blockHeaders[i],
          prefixLeafVal[1] // leafSum
        ), 'bad unused block gas');
      } else {
        require(verifyTransactionGas(
          blockHeaders[i],
          txNum,
          txNumKeys[i],
          subStack[0], // maxGasPrice
          prefixLeafVal[1], // leafSum
          txInclusionProofs[3*i], // tx inclusion proof
          txInclusionProofs[3*i+1], // receipt inclusion proof
          txInclusionProofs[3*i+2])); // prior receipt inclusion proof
      }
    }
    uint256 pGasVerified = verifyPGas(
      msmOpenings.length,
      subStack[4], // pGasClaimed
      subStack[6], // confidence
      subStack[5]); // alphaClaimed
    return maxCGas(
      pGasVerified,
      subStack[1], // disputeGasCost
      subStack[3] - subStack[2]); // endingBlockNum - startingBlockNum
  }
}