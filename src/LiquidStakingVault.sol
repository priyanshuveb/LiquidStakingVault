// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
// import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
// import {IERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWithdrawalNFT} from "./Interfaces/IWithdrawalNFT.sol";

contract LiquidStakingVault is ReentrancyGuard, ERC20 {

    // using SafeERC20 for IERC20;
    using Math for uint256;

    // ---------- Governor Executor as admin ----------
    address private _admin;
    uint256 public unbondingPeriod;
    
    IERC20 private immutable _asset;
    IWithdrawalNFT private immutable _nft;


    // ---------- Events / Errors ----------
    event Deposit(address indexed sender, uint256 assets, uint256 shares);
    event Withdraw(address indexed receiver, uint256 assets, uint256 shares, uint256 indexed tokenId, uint256 availableAt);
    event Claim(address indexed owner, uint256 assetsOwed, uint256 indexed tokenId, uint256 availableAt);
    event RewardsDistributed(address indexed caller, uint256 assets);

    error ExceededMaxWithdraw(address owner, uint256 requested, uint256 max);
    error NotUnlocked(uint256 currentTime, uint256 availableAt);
    error NotAdmin(address account);

    modifier onlyAdmin() {
        if (msg.sender != _admin) {
            revert NotAdmin(msg.sender);
        }
        _;
    }

    // ---------- Constructor ----------
    constructor(address admin_, IERC20 asset_, uint256 unbondingPeriod_, IWithdrawalNFT nft_) ERC20("LST Shares", "LSTS") {
        _admin = admin_;
        _asset = asset_;
        unbondingPeriod = unbondingPeriod_;
        _nft = nft_;
    }

    // ---------- CORE VALUT LOGICS ----------

    // ---------- Deposit assets, Minting shares ----------
    function deposit(uint256 assets) external nonReentrant returns (uint256) {
        uint256 shares = previewDeposit(assets);
        SafeERC20.safeTransferFrom(_asset, msg.sender, address(this), assets);
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, assets, shares);
        return shares;
    }
    // ---------- Minting shares by depositing assets ----------
    function mint(uint256 shares) public nonReentrant returns (uint256) {
        uint256 assets = previewMint(shares);
        SafeERC20.safeTransferFrom(_asset, msg.sender, address(this), assets);
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, assets, shares);
        return assets;
    }

    // ---------- Time-locked redemption via NFT ----------
    function inititateWithdraw(uint256 assets) external nonReentrant returns (uint256) {
        uint256 maxAssets = maxWithdraw(msg.sender);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(msg.sender, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);
        _burn(msg.sender, shares);

        uint256 availableAt = block.timestamp + unbondingPeriod;
        uint256 tokenId = _nft.mint(msg.sender, assets, availableAt);
    
        emit Withdraw(msg.sender, assets, shares, tokenId, availableAt);
        return shares;
    }
    // ---------- Claim after unbonding period ----------
    function claim(uint256 id_) external nonReentrant  {
        (uint256 assetsOwed, uint256 availableAt) = _nft.info(id_);
    
        if (block.timestamp < availableAt) {
            revert NotUnlocked(block.timestamp, availableAt);
        }
 
        _nft.burn(id_);
        SafeERC20.safeTransfer(_asset, msg.sender, assetsOwed);
        emit Claim(msg.sender, assetsOwed, id_, availableAt);
    }

    // ---------- ADMIN FUNCTIONS ----------

    // Push rewards without minting shares → ER increases.
    function distributeRewards(uint256 amount) external onlyAdmin nonReentrant {
  
        // _asset.safeTransferFrom(msg.sender, address(this), amount);
        SafeERC20.safeTransfer(_asset, address(this), amount);
        emit RewardsDistributed(msg.sender, amount);
    }

    function updateUnbondingPeriod(uint256 newPeriod) external onlyAdmin {
        unbondingPeriod = newPeriod;
    }

    function updateAdmin(address newAdmin) external onlyAdmin {
        _admin = newAdmin;
    }


    // ---------- VIEW FUNCTIONS ----------
    function admin() public view returns (address) {
        return _admin;
    }

    function asset() public view returns (address) {
        return address(_asset);
    }

    function nft() public view returns (address) {
        return address(_nft);
    }

    function totalAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function exchangeRate() public view returns (uint256) {
        (bool success, uint256 rate)  = (totalAssets() + 1).tryDiv(totalSupply() + 10 ** _decimalsOffset());
        return success ? rate : 0;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view returns(uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns(uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view returns(uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }

    function decimals() public view virtual override returns (uint8) {
        return  super.decimals() + _decimalsOffset();
    }

}