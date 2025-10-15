// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";


/// @notice Chain A executor: executes pre-authorized actionData after governance passes on Chain B.
/// actionData must be encoded as: abi.encode(address target, uint256 value, bytes data)
contract GovernanceExecutor is Ownable(msg.sender), ReentrancyGuard {
    using Address for address;

    /// @dev optional: restrict who can commit new action hashes (eg. GovernanceRootPublisher)
    address public committer;

    /// @dev action hash => allowed to execute
    mapping(bytes32 => bool) public authorized;

    /// @dev action hash => already executed (replay guard)
    mapping(bytes32 => bool) public executed;

    event CommitterUpdated(address indexed newCommitter);
    event ActionCommitted(bytes32 indexed actionHash);
    event ActionRevoked(bytes32 indexed actionHash);
    event ActionExecuted(bytes32 indexed actionHash, address indexed target, uint256 value, bytes data, bytes result);

    error NotAuthorized();
    error AlreadyExecuted();
    error InvalidAction();
    error NotCommitter();
    error ExecutionFailed();

    constructor(address _committer) {
        committer = _committer;
    }

    modifier onlyCommitter() {
        if (msg.sender != owner() && msg.sender != committer) revert NotCommitter();
        _;
    }

    /// @notice Owner can update the committer (usually GovernanceRootPublisher on Chain A).
    function setCommitter(address _committer) external onlyOwner {
        committer = _committer;
        emit CommitterUpdated(_committer);
    }

    /// @notice Pre-authorize an action hash (called by GovernanceRootPublisher during proposal creation/freeze).
    function commitAction(bytes32 actionDataHash) external onlyCommitter {
        authorized[actionDataHash] = true;
        emit ActionCommitted(actionDataHash);
    }

    /// @notice Allow owner/committer to revoke before execution if needed.
    function revoke(bytes32 actionDataHash) external onlyCommitter {
        authorized[actionDataHash] = false;
        emit ActionRevoked(actionDataHash);
    }

    /// @notice Execute a pre-authorized action. Anyone may call once authorized (permissionless execution).
    /// @dev actionData = abi.encode(target, value, data)
    function executeIfAuthorized(bytes calldata actionData)
        external
        payable
        nonReentrant
        returns (bool success, bytes memory result)
    {
        bytes32 actionHash = keccak256(actionData);
        if (!authorized[actionHash]) revert NotAuthorized();
        if (executed[actionHash]) revert AlreadyExecuted();

        (address target, uint256 value, bytes memory data) =
            abi.decode(actionData, (address, uint256, bytes));
        if (target == address(0)) revert InvalidAction();

        executed[actionHash] = true;

        // Execute
        (success, result) = target.call{value: value}(data);
        Address.verifyCallResult(success,"");
        emit ActionExecuted(actionHash, target, value, data, result);
    }

    // Allow receiving ETH if your actions need to forward value.
    receive() external payable {}
}
