// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IVaultLike {
    /// @return 1e18-scaled, floored exchange rate = totalAssets / totalShares (or 1e18 if no shares)
    function exchangeRate() external view returns (uint256);
}

contract GovernanceRootPublisher is Ownable(msg.sender) {
    struct Proposal {
        bytes32 actionDataHash;   // keccak256(abi.encode(target, callData))
        uint64  votingStart;      // unix seconds
        uint64  votingEnd;        // unix seconds
        uint64  snapshotBlock;    // L1/L2 block height for balance reads
        uint256 snapshotER;       // 1e18 scaled ER captured at creation

        // reserved for later phases (root freezing)
        bytes32 powerRoot;
        uint256 totalPower;
        uint256 quorum;
        uint256 threshold;
        bool    rootFrozen;
    }

    IVaultLike public immutable vault;
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;

    event ProposalCreated(
        uint256 indexed id,
        bytes32 indexed actionDataHash,
        uint64 votingStart,
        uint64 votingEnd,
        uint64 snapshotBlock,
        uint256 snapshotER
    );

    constructor(address vault_) {
        require(vault_ != address(0), "vault=0");
        vault = IVaultLike(vault_);
    }

    /// @notice Create a proposal and snapshot block+ER in one atomic step.
    /// @dev Keep window sane; you can relax constraints for tests.
    function createProposal(
        bytes32 actionDataHash,
        uint64 votingStart,
        uint64 votingEnd
    ) external onlyOwner returns (uint256 id) {
        require(actionDataHash != bytes32(0), "hash=0");
        require(votingStart < votingEnd, "window");
        require(votingStart >= block.timestamp, "start<present");

        id = ++proposalCount;

        proposals[id] = Proposal({
            actionDataHash: actionDataHash,
            votingStart: votingStart,
            votingEnd: votingEnd,
            snapshotBlock: uint64(block.number),
            snapshotER: vault.exchangeRate(),
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

    // ---------- Views that make off-chain life easy ----------
    function getSnapshot(uint256 id)
        external
        view
        returns (uint64 snapshotBlock, uint256 snapshotER)
    {
        Proposal storage p = proposals[id];
        require(p.snapshotBlock != 0, "no-proposal");
        return (p.snapshotBlock, p.snapshotER);
    }

    function getWindow(uint256 id)
        external
        view
        returns (uint64 votingStart, uint64 votingEnd)
    {
        Proposal storage p = proposals[id];
        require(p.snapshotBlock != 0, "no-proposal");
        return (p.votingStart, p.votingEnd);
    }
}
