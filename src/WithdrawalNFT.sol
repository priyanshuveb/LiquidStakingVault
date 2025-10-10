// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.20;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/** Minimal withdrawal receipt NFT */
contract WithdrawalNFT is ERC721, Ownable {

    error NonTransferable(address from, address to, uint256 tokenId);

    struct Withdrawal { uint256 assetsOwed; uint256 availableAt; }
    uint256 private _id;
    mapping(uint256 => Withdrawal) private _wd;

    constructor(address LSTVault) ERC721("LST Withdrawal", "LST-W") Ownable(LSTVault) {}

    function mint(address to, uint256 assetsOwed, uint256 availableAt)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        tokenId = ++_id;
        _safeMint(to, tokenId);
        _wd[tokenId] = Withdrawal({assetsOwed: assetsOwed, availableAt: availableAt});
    }

    function burn(uint256 tokenId) external onlyOwner {
        _burn(tokenId);
        delete _wd[tokenId];
    }

    function info(uint256 tokenId) external view returns (uint256 assetsOwed, uint256 availableAt) {
        Withdrawal memory w = _wd[tokenId];
        return (w.assetsOwed, w.availableAt);
    }

    function approve(address to, uint256 tokenId) public view override {
        revert NonTransferable(msg.sender, to, tokenId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert NonTransferable(msg.sender, to, tokenId);
        return super._update(to, tokenId, auth);
    }
}