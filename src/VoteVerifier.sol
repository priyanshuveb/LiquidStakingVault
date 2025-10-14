// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VoteVerifier is EIP712, Ownable {
   
    bytes32 public constant VOTE_TYPEHASH =
        keccak256("Vote(uint256 proposalId,bool support,address voter,uint256 power,uint256 nonce,uint256 deadline)");

    constructor() EIP712("CrossGov", "1") {}

    struct Meta {
        bytes32 powerRoot;       // Merkle root over keccak256(abi.encode(voter, power))
        bytes32 actionDataHash;  // must match Chain A publisher hash
        uint64  votingStart;     // unix seconds (optional enforcement)
        uint64  votingEnd;
        uint256 quorum;          // absolute participation requirement (power)
        uint256 threshold;       // "for" power needed to pass
        bool    frozen;          // set once per proposal by relayer/op
        bool    passed;          //  pass status
    }
    mapping(uint256 => Meta) public meta;

    event ProposalFrozen(uint256 indexed proposalId, bytes32 root, bytes32 actionDataHash, uint64 start, uint64 end, uint256 quorum, uint256 threshold);
    event VotesTallied(uint256 indexed proposalId, uint256 addFor, uint256 addAgainst, uint256 addAbstain);
    event ProposalPassed(uint256 indexed proposalId, bytes32 actionDataHash);

    error RootNotFrozen();
    error LengthMismatch();
    error InvalidMultiproof();
    error AlreadyFrozen();
    error Expired();
    error TooEarly();
    error TooLate();
    error AlreadyPassed();
    error NonceNotLatest();
    error InvalidSignature();
    error LeafMismatch();
    error DupVoter();
    error InvalidVote();

    /// @notice Called by your relayer after Chain A's GovernanceRootPublisher.freezeRoot().
    function freezeProposal(
        uint256 proposalId,
        bytes32 powerRoot,
        bytes32 actionDataHash,
        uint64 votingStart,
        uint64 votingEnd,
        uint256 quorum,
        uint256 threshold
    ) external onlyOwner {
        Meta storage m = meta[proposalId];
        require(!m.frozen, AlreadyFrozen());
        m.powerRoot = powerRoot;
        m.actionDataHash = actionDataHash;
        m.votingStart = votingStart;
        m.votingEnd = votingEnd;
        m.quorum = quorum;
        m.threshold = threshold;
        m.frozen = true;
        emit ProposalFrozen(proposalId, powerRoot, actionDataHash, votingStart, votingEnd, quorum, threshold);
    }

    // ====== Tally state ======
    struct Tally { uint256 forVotes; uint256 againstVotes; uint256 abstainVotes; }
    mapping(uint256 => Tally) public tallies;

    // per proposal: last nonce seen per voter (monotonic)
    mapping(uint256 => mapping(address => uint256)) public lastNonce;
    // per proposal: has this voter been counted already?
    mapping(uint256 => mapping(address => bool)) public hasCounted;

    function getNextNonce(uint256 proposalId, address voter) public view returns(uint256){
        return lastNonce[proposalId][voter] + 1;
    }

    struct VotePacked {
        uint256 proposalId;
        bool    support;     // true = yes, false = no; "abstain" handled via separate flag below
        address voter;
        uint256 power;       // must match Merkle leaf & snapshot power
        uint256 nonce;
        uint256 deadline;
        bool    abstain;     // if true, ignore support, tally as abstain
        bytes   signature;   // EIP-712 signature by voter
    }

    /// @notice Batch verify signatures + Merkle multiproof, then tally.
    function batchVerifyAndTally(
        VotePacked[] calldata votes,
        bytes32[] calldata leaves,
        bytes32[] calldata proof,
        bool[] calldata proofFlags
    ) external {
        require(votes.length == leaves.length, LengthMismatch());
        require(votes.length > 0, "empty");

        uint256 proposalId = votes[0].proposalId;
        Meta storage m = meta[proposalId];
        require(m.frozen, RootNotFrozen());
        if (m.votingStart != 0) require(block.timestamp >= m.votingStart, TooEarly());
        if (m.votingEnd   != 0) require(block.timestamp <= m.votingEnd, TooLate());
        require(!m.passed, AlreadyPassed());

        // 1) EIP-712 verify each vote and validate leaf matches (voter,power)
        uint256 addFor; uint256 addAgainst; uint256 addAbstain;

        for (uint256 i = 0; i < votes.length; ++i) {
            VotePacked calldata v = votes[i];
            require(v.proposalId == proposalId, InvalidVote());
            require(block.timestamp <= v.deadline, Expired());
            // nonce monotonic
            uint256 prev = lastNonce[proposalId][v.voter];
            require(v.nonce > prev, NonceNotLatest());
            lastNonce[proposalId][v.voter] = v.nonce;

            // dedup: only first counted per proposal (after nonce check). If you prefer "latest overrides", drop hasCounted and rely purely on nonce.
            require(!hasCounted[proposalId][v.voter], DupVoter());
            hasCounted[proposalId][v.voter] = true;

            // typed data recovery
            bytes32 digest = _hashTypedDataV4(
                keccak256(abi.encode(
                    VOTE_TYPEHASH,
                    v.proposalId,
                    v.support,
                    v.voter,
                    v.power,
                    v.nonce,
                    v.deadline
                ))
            );
            address rec = ECDSA.recover(digest, v.signature);
            require(rec == v.voter, InvalidSignature());

            // leaf check: keccak256(abi.encode(address,uint256))
            bytes32 leaf = keccak256(abi.encode(v.voter, v.power));
            require(leaf == leaves[i], LeafMismatch());

            // local tally accumulators (Merkle checked after loop)
            if (v.abstain) {
                addAbstain += v.power;
            } else if (v.support) {
                addFor += v.power;
            } else {
                addAgainst += v.power;
            }
        }

        // 2) Multi-proof verify for all leaves in this batch
        require(MerkleProof.multiProofVerify(proof, proofFlags, m.powerRoot, leaves), InvalidMultiproof());

        // 3) Apply tallies & check pass
        Tally storage t = tallies[proposalId];
        t.forVotes     += addFor;
        t.againstVotes += addAgainst;
        t.abstainVotes += addAbstain;
        emit VotesTallied(proposalId, addFor, addAgainst, addAbstain);

        // participation for quorum = all counted (yes + no + abstain)
        uint256 participation = t.forVotes + t.againstVotes + t.abstainVotes;

        if (!m.passed && t.forVotes >= m.threshold && participation >= m.quorum) {
            m.passed = true;
            emit ProposalPassed(proposalId, m.actionDataHash);
        }
    }
}
