pragma solidity ^0.8.20;

interface IWithdrawalNFT {
    function mint(address to, uint256 assetsOwed, uint256 availableAt) external returns (uint256 tokenId);
    function burn(uint256 tokenId) external;
    function info(uint256 tokenId) external view returns (uint256 assetsOwed, uint256 availableAt);
    function ownerOf(uint256 tokenId) external view returns (address);
}