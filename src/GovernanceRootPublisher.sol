// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IVault {
    function exchangeRate() external view returns (uint256);
}

contract GovernanceRootPublisher is Ownable(msg.sender) {
    struct Proposal {
        bytes32 actionDataHash;   // keccak256(abi.encode(target, callData))
        uint64  votingStart;      // unix seconds
        uint64  votingEnd;        // unix seconds
        uint64  snapshotBlock;    
        uint256 snapshotER;       // 1e18 scaled ER captured at creation
        uint256 deadline;         // deadline to vote and execute the proposal

        // reserved for later phases (root freezing)
        bytes32 powerRoot;
        uint256 totalPower;
        uint256 quorum;
        uint256 threshold;
        bool    rootFrozen;
    }

    IVault public immutable vault;

    uint256 public proposalCount;

    uint256 constant public buffer = 2 days; // buffer time to execute the proposal after the voting ends

    mapping(uint256 => Proposal) public proposals;

    event ProposalCreated(
        uint256 indexed id,
        bytes32 indexed actionDataHash,
        uint64 votingStart,
        uint64 votingEnd,
        uint64 snapshotBlock,
        uint256 snapshotER
    );
    event RootPublished(
        uint256 indexed proposalId,
        bytes32 indexed powerRoot,
        uint256 totalPower,
        uint256 quorum,
        uint256 threshold
    );

    error NoProposal();
    error RootAlreadyPublished();
    error InvalidActionData();
    error InvalidVotingPeriod();
    error InvalidVaultAddress();

    constructor(address vault_) {
        require(vault_ != address(0), InvalidVaultAddress());
        vault = IVault(vault_);
    }

    function createProposal(
        bytes32 actionDataHash,
        uint64 votingStart,
        uint64 votingEnd
    ) external returns (uint256 id) {
        require(actionDataHash != bytes32(0), InvalidActionData());
        require(votingStart < votingEnd, InvalidVotingPeriod());
        require(votingStart >= block.timestamp, InvalidVotingPeriod());

        id = ++proposalCount;

        proposals[id] = Proposal({
            actionDataHash: actionDataHash,
            votingStart: votingStart,
            votingEnd: votingEnd,
            snapshotBlock: uint64(block.number),
            snapshotER: vault.exchangeRate(),
            deadline: votingEnd + buffer,
            powerRoot: bytes32(0),
            totalPower: 0,
            quorum: 0,
            threshold: 0,
            rootFrozen: false
        });

        emit ProposalCreated(
            id,
            actionDataHash,
            votingStart,
            votingEnd,
            uint64(block.number),
            proposals[id].snapshotER
        );
    }

    function publishRoot(
        uint256 proposalId,
        bytes32 powerRoot,
        uint256 totalPower,
        uint256 quorum,
        uint256 threshold
    ) external onlyOwner {
        Proposal storage p = proposals[proposalId];
        require(p.snapshotBlock != 0, NoProposal());
        require(!p.rootFrozen, RootAlreadyPublished());

        p.powerRoot = powerRoot;
        p.totalPower = totalPower;
        p.quorum = quorum;
        p.threshold = threshold;
        p.rootFrozen = true;

        emit RootPublished(proposalId, powerRoot, totalPower, quorum, threshold);
    }

    // ---------- Views that make off-chain life easy ----------
    function getSnapshot(uint256 id)
        external
        view
        returns (uint64 snapshotBlock, uint256 snapshotER)
    {
        Proposal storage p = proposals[id];
        require(p.snapshotBlock != 0, NoProposal());
        return (p.snapshotBlock, p.snapshotER);
    }

    function getWindow(uint256 id)
        external
        view
        returns (uint64 votingStart, uint64 votingEnd)
    {
        Proposal storage p = proposals[id];
        require(p.snapshotBlock != 0, NoProposal());
        return (p.votingStart, p.votingEnd);
    }

    function getDeadline(uint256 id) external view returns(uint256){
        Proposal memory p = proposals[id];
        require(p.deadline != 0, NoProposal());
        return p.deadline;

    }
} 
