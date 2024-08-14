// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title DecentralizedStableCoin
 * @author Inderdeep Singh
 * Collateral : Exogenous
 * Minting : Algorithmic
 * Relative Stability : Pegged to USD
 * @notice This Contract is meant to be governed by DSCEngine. This is just the ERC20 implementation of the StableCoin
*/
contract DecentralizedStableCoin is ERC20Burnable, Ownable{
    error DecentralizedStableCoin__NegativeOrZeroBurnAmount();
    error DecentralizedStableCoin__NotEnoughBalanceToBurn();
    error DecentralizedStableCoin__MintToZeroAddress();
    error DecentralizedStableCoin__MintZeroAmount();

    constructor() ERC20("Decentralized Stable Coin", "DSC") Ownable(msg.sender){}

    function burn(uint256 _amount) public override onlyOwner {
        if(_amount <= 0){
            revert DecentralizedStableCoin__NegativeOrZeroBurnAmount();
        }
        uint256 balance = balanceOf(msg.sender);
        if(balance < _amount){
            revert DecentralizedStableCoin__NotEnoughBalanceToBurn();
        }
        super._burn(msg.sender, _amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns(bool){
        if(_to == address(0)){
            revert DecentralizedStableCoin__MintToZeroAddress();
        }
        if(_amount <= 0){
            revert DecentralizedStableCoin__MintZeroAmount();
        }
        _mint(_to, _amount);
        return true;
    }
}
