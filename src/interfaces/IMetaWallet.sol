// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IHookExecution } from "./IHookExecution.sol";
import { IVaultModule } from "./IVaultModule.sol";
import { IMinimalSmartAccount } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";
import { IERC7540 } from "./IERC7540.sol";

interface IMetaWallet is IERC7540, IVaultModule, IMinimalSmartAccount, IHookExecution { }
