# Chain A (Stake Chain)

### Components
- LST contract
    1. ERC-4626 like contract
    2. non-rebasing token
    3. exchangeRate = totalAssets / totalShares
    4. mulDiv math for rounding
    5. time-locked redemptions
    5. withdraw burn shares and mint withdraw nft containing assets owned and availableAt = now() + unbondingPeriod to claim assets

- GovernanceRootPublisher
    1. create proposal
    2. snapshot excahnge rate
    3. snapshot block
    4. 


### Flow
- LSTVault -> 
    1. deposit/mint
    2. shares model (ERC-4626)
    3. distribute rewards
    4. withdraw with burning shares -> withdrawal nft
    5. claim after the unbonding period ends

- GovernanceRootPublisher ->
    1. create proposals
    2. snapshot

- GovernorExecutor ->
    1. execute proposals


# Chain B (Verify Chain)

### Flow
- Flow ->
    1. verify off chain vote (eip-712)
    2. verify merkle proofs
    3. tally votes
    4. emit ProposalPassed event


