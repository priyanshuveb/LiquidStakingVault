// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LiquidStakingVault} from "../src/LiquidStakingVault.sol";
import {WithdrawalNFT} from "../src/WithdrawalNFT.sol";
import {Asset} from "../src/Asset.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract VaultTest is Test {
    LiquidStakingVault vault;
    WithdrawalNFT nft;
    Asset asset;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob   = address(0xCAFE);

    uint256 constant INIT_UNBOND = 7 days;

    function setUp() public {
        // Deploy real ERC20 + vault
        asset = new Asset();
        vault = new LiquidStakingVault(admin, asset, INIT_UNBOND);

        // Deploy real WithdrawalNFT with vault as owner
        nft = new WithdrawalNFT(address(vault));

        // Admin sets NFT on vault
        vm.prank(admin);
        vault.setNFT(address(nft));

        vm.startPrank(alice);
        asset.mint();
        vm.stopPrank();

        vm.startPrank(bob);
        asset.mint();
        vm.stopPrank();

        vm.startPrank(admin);
        asset.mint();
        vm.stopPrank();

        // Approvals
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(admin);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /* ===================== Exchange rate & share math ===================== */

    function test_InitialExchangeRateIs1e18() public {
        // ER = (totalAssets+1)*1e18 / (totalSupply+1)
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.exchangeRate(), 1e18);
    }

    function test_Deposit_MintsSharesAtER1() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether);

        // With ER≈1e18 initially, shares ≈ assets
        uint256 expected = vault.previewDeposit(100 ether);
        assertEq(shares, expected);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(vault.balanceOf(alice), shares);

        // maxWithdraw uses floor convertToAssets
        assertEq(vault.maxWithdraw(alice), 100 ether);
    }

    function test_MintSharesAtER1() public {
        vm.prank(alice);
        // previewMint uses CEIL on required assets -> here exactly 50
        uint256 required = vault.previewMint(50 ether);
        assertEq(required, 50 ether);

        vm.prank(alice);
        uint256 spent = vault.mint(50 ether);
        assertEq(spent, 50 ether);

        assertEq(vault.balanceOf(alice), 50 ether);
        assertEq(vault.totalAssets(), 50 ether);
    }

    function test_DistributeRewards_IncreasesER() public {
        // Deposit first
        vm.prank(alice);
        vault.deposit(100 ether);
        uint256 er0 = vault.exchangeRate();

        // Push rewards from admin (no share mint → ER rises)
        vm.prank(admin);
        vault.distributeRewards(50 ether);

        assertEq(vault.totalAssets(), 150 ether);
        uint256 er1 = vault.exchangeRate();
        assertGt(er1, er0);
    }

    function test_Rounding_FloorOnDeposit_CeilOnWithdrawPreviews() public {
        // Create tiny balances to see rounding behavior
        vm.prank(alice);
        vault.deposit(3); // 3 wei

        // previewDeposit (Floor) undercounts shares (never over-credits)
        uint256 sh = vault.previewDeposit(1);
        assertLe(sh, 1);

        // previewWithdraw (Ceil) requires enough shares to cover requested assets
        uint256 sharesNeeded = vault.previewWithdraw(1);
        assertGe(sharesNeeded, 1);
    }

    /* ===================== Time-locked redemption via NFT ===================== */

function test_InitiateWithdraw_MintsNFT_BurnsShares() public {
    vm.prank(alice);
    vault.deposit(100 ether);

    uint256 assetsToWithdraw = 60 ether;

    // compute before state changes
    uint256 expectedBurn = vault.previewWithdraw(assetsToWithdraw);

    uint256 tsBefore = vault.totalSupply();
    uint256 balBefore = vault.balanceOf(alice);

    vm.prank(alice);
    uint256 burned = vault.inititateWithdraw(assetsToWithdraw);

    assertEq(burned, expectedBurn);
    assertEq(vault.totalSupply(), tsBefore - burned);
    assertEq(vault.balanceOf(alice), balBefore - burned);
    // totalAssets unchanged until claim
    assertEq(vault.totalAssets(), 100 ether);
}


    function test_Claim_RevertsBeforeUnlock() public {
        vm.prank(alice);
        vault.deposit(100 ether);

        vm.prank(alice);
        vault.inititateWithdraw(40 ether);

        // tokenId in our NFT starts at 1
        vm.expectRevert(); // NotUnlocked
        vm.prank(alice);
        vault.claim(1);
    }

    function test_Claim_AfterUnbonding_TransfersAssets() public {
        vm.prank(alice);
        vault.deposit(100 ether);

        vm.prank(alice);
        vault.inititateWithdraw(40 ether);

        // Wait past unbonding
        vm.warp(block.timestamp + INIT_UNBOND + 1);

        uint256 beforeBal = asset.balanceOf(alice);
        vm.prank(alice);
        vault.claim(1);
        uint256 afterBal = asset.balanceOf(alice);

        assertEq(afterBal - beforeBal, 40 ether);
        assertEq(vault.totalAssets(), 60 ether); // 100 - 40
    }

function test_InitiateWithdraw_RevertsIfExceedsMax() public {
    vm.prank(alice);
    vault.deposit(10 ether);

    bytes4 sel = bytes4(keccak256("ExceededMaxWithdraw(address,uint256,uint256)"));
    vm.expectRevert();

    vm.prank(alice);
    vault.inititateWithdraw(11 ether);
}

    /* ===================== Admin behavior & guards ===================== */

    function test_OnlyAdmin_SetNFT_OnlyOnce() public {
        // Already set in setUp; attempting again should revert
        vm.expectRevert(LiquidStakingVault.NFTAlreadySet.selector);
        vm.prank(admin);
        vault.setNFT(address(nft));

        // Non-admin cannot set on a fresh vault
        LiquidStakingVault v2 = new LiquidStakingVault(admin, asset, INIT_UNBOND);
        WithdrawalNFT nft2 = new WithdrawalNFT(address(v2));
        vm.expectRevert(abi.encodeWithSelector(LiquidStakingVault.NotAdmin.selector, bob));
        vm.prank(bob);
        v2.setNFT(address(nft2));
    }

    function test_OnlyAdmin_DistributeRewards() public {
        vm.prank(admin);
        vault.distributeRewards(10 ether); // ok

        vm.expectRevert(abi.encodeWithSelector(LiquidStakingVault.NotAdmin.selector, alice));
        vm.prank(alice);
        vault.distributeRewards(1 ether);
    }

    function test_UpdateUnbondingPeriod_And_AdminTransfer() public {
        vm.prank(admin);
        vault.updateUnbondingPeriod(3 days);
        assertEq(vault.unbondingPeriod(), 3 days);

        vm.expectRevert(abi.encodeWithSelector(LiquidStakingVault.NotAdmin.selector, alice));
        vm.prank(alice);
        vault.updateUnbondingPeriod(1 days);

        vm.prank(admin);
        vault.updateAdmin(bob);
        assertEq(vault.admin(), bob);

        // old admin no longer authorized
        vm.expectRevert(abi.encodeWithSelector(LiquidStakingVault.NotAdmin.selector, admin));
        vm.prank(admin);
        vault.updateUnbondingPeriod(5 days);

        // new admin can
        vm.prank(bob);
        vault.updateUnbondingPeriod(5 days);
        assertEq(vault.unbondingPeriod(), 5 days);
    }

    /* ===================== Acceptance-ish vault flow ===================== */

    function test_Acceptance_VaultFlow() public {
        // 1) deposit
        vm.prank(alice);
        vault.deposit(100 ether);
        uint256 er0 = vault.exchangeRate();

        // 2) rewards
        vm.prank(admin);
        vault.distributeRewards(25 ether);

        // 3) ER increases
        uint256 er1 = vault.exchangeRate();
        assertGt(er1, er0);

        // 4) initiate withdraw 50, then claim after unlock
        vm.prank(alice);
        vault.inititateWithdraw(50 ether);

        vm.expectRevert();
        vm.prank(alice);
        vault.claim(1);

        vm.warp(block.timestamp + vault.unbondingPeriod() + 1);

        vm.prank(alice);
        vault.claim(1);

        // Post state: 100 + 25 rewards - 50 claimed = 75 left
        assertEq(vault.totalAssets(), 75 ether);
    }

    /* ===================== Misc sanity ===================== */

    function test_MaxWithdraw_EqualsBalanceInAssets_Floor() public {
        vm.prank(alice);
        vault.deposit(123 ether);
        assertEq(vault.maxWithdraw(alice), 123 ether);
    }

    function test_Decimals_Default18() public {
        assertEq(vault.decimals(), 18);
    }
}
