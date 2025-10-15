# LiquidStaking with Cross Chain Governance (Off Chain Voting) Contracts

This repo contains the **on-chain contracts** for the “Liquid Staking + Off-Chain Voting + Cross-Chain Execution” system.  
It is split across two logical chains:

- **Chain A (Stake chain):** staking vault, withdrawal NFT, governance root publisher, governance executor.
- **Chain B (Verify chain):** vote verifier that checks EIP-712 signatures and a Merkle **multi-proof** of voter powers, tallies votes, and emits `ProposalPassed`.

The companion frontend + backend (mini-Snapshot) lives in a separate repo and handles **off-chain** vote collection, power computation at the snapshot, and Merkle artifact generation.

---

## Table of Contents

- [Architecture](#architecture)
- [Contracts](#contracts)
  - [Asset (ERC20)](#1-asset-erc20-chain-a)
  - [WithdrawalNFT (ERC721)](#2-withdrawalnft-erc721-chain-a)
  - [LiquidStakingVault](#3-liquidstakingvault-chain-a)
  - [GovernanceRootPublisher](#4-governancerootpublisher-chain-a)
  - [VoteVerifier](#5-voteverifier-chain-b)
  - [GovernanceExecutor](#6-governanceexecutor-chain-a)
- [Voting Power & Math](#voting-power--math)
- [Merkle Tree & Multi-Proof Spec](#merkle-tree--multi-proof-spec)
- [Cross-Chain Flow](#cross-chain-flow)
- [Security & Assumptions](#security--assumptions)
- [Development](#development)
- [Testing Guide](#testing-guide)
- [Deployment & Scripts](#deployment--scripts)
- [Appendix](#appendix)

---

## Architecture

```
Chain A (Stake)
 ├─ Asset (ERC20)     - underlying token users deposit
 ├─ LiquidStakingVault
 │   ├─ ERC20 shares (LST)
 │   ├─ time-locked withdrawals -> WithdrawalNFT receipts
 │   └─ rewards pushed via distributeRewards() -> ER ↑ over time
 ├─ WithdrawalNFT     - non-transferable withdrawal receipts
 ├─ GovernanceRootPublisher
 │   ├─ createProposal(): captures snapshot {block, ER}
 │   └─ publishRoot(): freezes root + params after voting
 └─ GovernanceExecutor
     └─ executeIfAuthorized(actionData): executes actions when relayed

Chain B (Verify)
 └─ VoteVerifier
     ├─ freezeProposal(): freeze proposal params & power root
     ├─ batchVerifyAndTally(): verify EIP-712 + Merkle multiproof, tally
     └─ emits ProposalPassed(proposalId, actionDataHash)
```

- **Off-chain** service (frontend server) computes snapshot power per voter, dedups by highest nonce, builds a Merkle tree of `(voter, power)` leaves, and provides multiproofs to Chain B.
- A simple **relayer** listens on Chain B for `ProposalPassed` and calls Chain A’s `GovernanceExecutor.executeIfAuthorized(actionData)`.

---

## Contracts

### 1) Asset (ERC20, Chain A)

Demo ERC20 with a faucet helper for local testing.

- **Key functions**
  - `mint()` – mints large supply to caller (demo only).
  - `getAsset()` – transfers 100 ASSET to caller (demo faucet).
- **Notes**  
  In production this would be a real underlying asset.

---

### 2) WithdrawalNFT (ERC721, Chain A)

**Non-transferable** withdrawal receipt. Owned by the vault.

- **State**
  - `mapping(uint256 => Withdrawal)` where `Withdrawal { uint256 assetsOwed; uint256 availableAt; }`
- **Key functions**
  - `mint(to, assetsOwed, availableAt) onlyOwner → tokenId`
  - `burn(tokenId) onlyOwner`
  - `info(tokenId) → (assetsOwed, availableAt)`
- **Transfer restrictions**
  - Overrides `approve` and `_update` to make receipts **soulbound** (non-transferable).

---

### 3) LiquidStakingVault (Chain A)

Non-rebasing LST vault (ERC20 shares). ERC-4626-like math (no formal 4626 inheritance).

- **Core ideas**
  - **Shares model**: `exchangeRate = totalAssets / totalShares`, **scaled by 1e18**.
  - **Rounding**: uses OpenZeppelin `Math.mulDiv(..., Math.Rounding.Floor)` to **favor under-counting**.
  - **Redemptions time-locked**: `initiateWithdraw(assets)` burns shares and mints **WithdrawalNFT** with `(assetsOwed, availableAt = now + unbondingPeriod)`; `claim()` transfers ASSET after unlock.

- **Key state**
  - `_asset` – underlying ERC20
  - `_nft` – `WithdrawalNFT` address
  - `unbondingPeriod`
  - `ER_SCALE = 1e18`

- **Key functions**
  - `deposit(assets) → shares` – transfer ASSET in, mint shares (floor).
  - `mint(shares) → assets` – mint target shares by depositing assets (ceil).
  - `distributeRewards(amount) onlyAdmin` – push rewards (ASSET) into the vault to increase ER without minting shares.
  - `inititateWithdraw(assets) → shares` – **(typo preserved for compatibility)** burns the necessary shares, mints receipt NFT.
  - `claim(tokenId)` – transfers `assetsOwed` to caller if `block.timestamp >= availableAt` and burns NFT.
  - `exchangeRate() view → uint256` – `floor((totalAssets+1) * 1e18 / (totalShares+1))`.  
    `+1` guards division-by-zero in early states while maintaining under-counting bias.
  - Conversion helpers (floor/ceil where appropriate):
    - `_convertToShares(assets, rounding)`
    - `_convertToAssets(shares, rounding)`
    - `previewDeposit/previewMint/previewWithdraw/maxWithdraw`

- **Admin functions**
  - `setNFT(address)` – one-time set.
  - `updateUnbondingPeriod(uint256)` – used as a governance action.
  - `updateAdmin(address)`

- **Events**
  - `Deposit(sender, assets, shares)`
  - `Withdraw(receiver, assets, shares, tokenId, availableAt)`
  - `Claim(owner, assetsOwed, tokenId, availableAt)`
  - `RewardsDistributed(caller, amount)`

---

### 4) GovernanceRootPublisher (Chain A)

Creates proposals, captures snapshot data, and later **publishes** the power root + thresholds.

- **Snapshot captured at create time**
  - `snapshotBlock` – block number on Chain A.
  - `snapshotER` – exchange rate of LST at snapshot (scaled 1e18).

- **Voting power formula at snapshot**  
  Off-chain service must compute:
  ```
  power = ASSET_balance_at_snapshot
        + floor(LST_balance_at_snapshot * snapshotER / 1e18)
  ```

- **Lifecycle**
  - `createProposal(bytes32 actionDataHash, uint64 votingStart, uint64 votingEnd) → proposalId`
    - Stores `snapshotBlock`, `snapshotER`, `window`.
  - `publishRoot(proposalId, bytes32 powerRoot, uint256 totalPower, uint256 quorum, uint256 threshold) onlyOwner`
    - Freezes the power root for this proposal on Chain A.

- **Why publish on A and B?**  
  Publishing on Chain A is the governance source of truth; freezing again on Chain B lets the verifier enforce the same root + voting window and reclaim proofs cost-effectively.

- **Events**
  - `RootPublished(proposalId, powerRoot, totalPower, quorum, threshold)`

---

### 5) VoteVerifier (Chain B)

Verifies **EIP-712** signatures & Merkle **multi-proofs** for batched votes, tallies, and determines pass status.

- **EIP-712 domain (on B)**
  - name: `CrossGov`
  - version: `1`
  - chainId: Chain B’s chainId
  - verifyingContract: `VoteVerifier` address

- **Typed struct**
  ```
  Vote(
    uint256 proposalId,
    bool    support,
    address voter,
    uint256 power,
    uint256 nonce,
    uint256 deadline
  )
  ```
  > `abstain` is carried in the calldata struct but excluded from the signature per the requirement.

- **Meta per proposal**
  ```
  struct Meta {
    bytes32 powerRoot;        // root over keccak256(abi.encode(voter, power))
    bytes32 actionDataHash;   // must match Chain A publisher hash
    uint64  votingStart;      // unix seconds (optional enforcement)
    uint64  votingEnd;
    uint256 quorum;           // absolute participation power
    uint256 threshold;        // "for" power to pass
    bool    frozen;           // proposal params frozen
    bool    passed;           // final status
  }
  mapping(uint256 => Meta) public meta;
  ```

- **Tallies**
  ```
  struct Tally { uint256 forVotes; uint256 againstVotes; uint256 abstainVotes; }
  mapping(uint256 => Tally) public tallies;
  ```

- **Anti-double-count**
  ```
  mapping(uint256 => mapping(address => uint256)) public lastNonce;
  mapping(uint256 => mapping(address => bool))    public hasCounted;
  ```

- **Key functions**
  - `freezeProposal(proposalId, root, actionDataHash, start, end, quorum, threshold) onlyOwner`
  - `getNextNonce(proposalId, voter) view → uint256`
  - `batchVerifyAndTally(VotePacked[] votes, bytes32[] leaves, bytes32[] proof, bool[] proofFlags)`
    1. Check meta (frozen, window, not passed).
    2. For each vote:
       - Enforce `deadline`, monotonic `nonce` (`nonce > lastNonce`), and **first-count** (or switch to “latest overrides” by removing `hasCounted`).
       - Recover signer via EIP-712 digest; must equal `v.voter`.
       - Require `keccak256(abi.encode(v.voter, v.power)) == leaves[i]`.
    3. Verify **Merkle multiproof** for batch: `multiProofVerify(proof, proofFlags, root, leaves)`.
    4. Apply to accumulators; if `forVotes ≥ threshold && participation ≥ quorum`, set `passed = true` and emit:
       - `ProposalPassed(proposalId, actionDataHash)`

---

### 6) GovernanceExecutor (Chain A)

Thin executor that **commits** to a set of authorized `actionDataHash` values, and only executes calls matching a passed proposal from Chain B (relayed off-chain).

- **Action encoding**  
  ```
  actionData = abi.encode(
    address target,
    uint256 value,          // usually 0
    bytes   callData        // e.g., vault.updateUnbondingPeriod(…)
  )
  actionDataHash = keccak256(actionData)
  ```
- **Key functions**
  - `authorize(bytes32 actionDataHash) onlyOwner` – commit allowed actions (or rely on Publisher proposals).
  - `executeIfAuthorized(bytes calldata actionData) external` – check hash committed & matches the passed proposal, then perform the call. Emit event with success/failure.

> In this challenge, the **relayer** is the trust anchor between chains. There is no bridge; you enforce correctness by hashing the full `actionData` and matching across chains.

---

## Voting Power & Math

- **Non-rebasing shares** (Vault issues ERC20 LST):
  ```
  exchangeRate = floor( (totalAssets + 1) * 1e18 / (totalShares + 1) )
  ```
  - `+1` guards division by zero at bootstrap and preserves floor bias.
  - Rewards deposited via `distributeRewards()` raise `totalAssets` without minting shares → **ER increases**.

- **Power at snapshot (off-chain)**:
  ```
  power = ASSET_balance_at_snapshot
        + floor( LST_balance_at_snapshot * snapshotER / 1e18 )
  ```
- **Rounding**: Consistently **floor** where users could gain by rounding. Favor under-counting to make rounding exploits unprofitable.

---

## Merkle Tree & Multi-Proof Spec

- **Leaves**: `leaf = keccak256(abi.encode(voter, power))`
- **Tree**: Fixed order (e.g., checksum address sorting) to make roots reproducible.
- **Artifacts** (written by backend):
  - `root` – 32-byte Merkle root
  - `voters[]` – ordered `(voter, power, support, nonce)` after dedup by highest `nonce`
  - `leaves[]` – ordered leaves for those voters
  - `proof[]`, `proofFlags[]` – **multiproof** over the selected leaves (can be **empty** when proving all leaves on small trees; flags suffice)
- **On-chain check (B)**:
  - `MerkleProof.multiProofVerify(proof, proofFlags, root, leaves) == true`

---

## Cross-Chain Flow

1. **Deposit & LST**: users deposit ASSET into the vault on **A** → receive LST (shares). Rewards can be added via `distributeRewards`.
2. **Create Proposal**: on **A**, `createProposal(actionDataHash, start, end)` records `snapshotBlock` + `snapshotER`.
3. **Off-chain voting**: users sign EIP-712 votes; server recomputes **power at snapshot**, verifies signatures off-chain, dedups to highest nonce per voter, stores `votes.json`.
4. **Freeze root**:
   - On **A**: `publishRoot(proposalId, powerRoot, totalPower, quorum, threshold)`
   - On **B**: `freezeProposal(...)` with the **same root & window`.
5. **Batch Verify**: call `batchVerifyAndTally(votes, leaves, proof, proofFlags)` on **B`. If quorum+threshold met, emits `ProposalPassed(proposalId, actionDataHash)`.
6. **Relay**: off-chain script listens to B’s event, submits `actionData` to **A**’s `GovernanceExecutor.executeIfAuthorized(actionData)` for execution (hash must match).

---

## Security & Assumptions

- **Off-chain correctness**: The backend must compute snapshot balances and ER accurately and freeze the **correct** root. This is the main trust assumption in off-chain voting.
- **Rounding policy**: Always round in a way that cannot be exploited for gain (use `Floor` where appropriate).
- **Nonces**: Each voter tracked per proposal; only **newer nonce** votes are accepted.
- **Abstain**: Signed payload excludes the `abstain` flag (per requirement), but it’s included in calldata and tally logic.
- **Withdrawal NFT**: Non-transferable to prevent secondary market manipulation of unbonding receipts.
- **Executor**: Executes **only** pre-authorized `actionDataHash`es that match passed proposals. There is no bridge; your relayer enforces liveness and sequencing.
- **Reentrancy & Safe transfers**: Vault uses `ReentrancyGuard` and `SafeERC20`.

---

## Development

### Tooling

- **Solidity**: `^0.8.20` (some contracts use `^0.8.26` with OZ 5.x utils)
- **Package**: OpenZeppelin contracts
- **Framework**: Foundry (forge + anvil)

### Common Commands

```bash
forge build
forge test -vv
anvil
```

---

## Testing Guide

**Acceptance tests to cover:**

1. **Appreciating LST**  
   - Deposit `X` ASSET → mint shares  
   - `distributeRewards(R)` → `exchangeRate` increases; `previewWithdraw` yields more assets per share.
2. **Time-locked redeem**  
   - `initiateWithdraw(assets)` → shares burned, NFT minted, `availableAt = now + unbondingPeriod`  
   - Before unlock → `claim` reverts; after unlock → `claim` transfers `assetsOwed` and burns NFT.
3. **Dual voting power**  
   - At `snapshotBlock`, compute `ASSET_at_snapshot` and `LST_at_snapshot` for test accounts.  
   - Verify `power` equals `ASSET + floor(LST * ER / 1e18)`.
4. **Governance flow** (end-to-end)  
   - `createProposal` on A → snapshot stored  
   - Off-chain build votes + root → `publishRoot` on A; `freezeProposal` on B  
   - `batchVerifyAndTally` on B → if pass, `ProposalPassed` emitted  
   - Relayer calls Executor on A → action takes effect (e.g. `updateUnbondingPeriod`).

**Additional unit tests:**

- **mulDiv rounding** edge cases (`totalShares==0`, small supplies, large rewards).  
- **initiateWithdraw math**: shares burned == `ceil(assets / ER)`.  
- **Non-transferable NFT**: secondary transfer attempts revert.  
- **VoteVerifier**: bad domain, bad signature, stale/non-monotonic nonce, mismatched leaf, invalid multiproof, outside voting window, double-count defense.  
- **Executor**: rejects unauthorized `actionDataHash`, mismatched hashes, failed target calls bubble or emit failure.

---

## Deployment & Scripts

> Use the separate **scripts** repo (frontend/backend) to coordinate these steps.

- **Create action data**  
  `actionData.js` →  
  `actionData = abi.encode(target, value, calldata)`, `actionDataHash = keccak256(actionData)`
- **Create proposal** on A with `actionDataHash`.
- **Freeze power root** on A: `publishRoot.js`
- **Freeze proposal** on B: `publishRoot.js` (second call) or a dedicated `freezeProposal` script.
- **Batch verify on B**: `batchVerifyAndTally.js` (builds votes[], leaves[], proof[], flags[] from `data/merkle.json`).
- **Relay**: `relayer.js` listens on B for `ProposalPassed` and executes on A via `executeIfAuthorized(actionData)`.

---

## Appendix

### EIP-712 TypeHash

```
VOTE_TYPEHASH = keccak256(
  "Vote(uint256 proposalId,bool support,address voter,uint256 power,uint256 nonce,uint256 deadline)"
)
```

### Domain (Chain B)

```
name    = "CrossGov"
version = "1"
chainId = <Chain B ID>
verifyingContract = <VoteVerifier>
```

### Events

- **VoteVerifier (B)**
  - `ProposalFrozen(uint256 id, bytes32 root, bytes32 actionDataHash, uint64 start, uint64 end, uint256 quorum, uint256 threshold)`
  - `VotesTallied(uint256 id, uint256 addFor, uint256 addAgainst, uint256 addAbstain)`
  - `ProposalPassed(uint256 id, bytes32 actionDataHash)`

- **GovernanceRootPublisher (A)**
  - `RootPublished(uint256 id, bytes32 root, uint256 totalPower, uint256 quorum, uint256 threshold)`

- **LiquidStakingVault (A)**
  - `Deposit(...)`, `Withdraw(...)`, `Claim(...)`, `RewardsDistributed(...)`