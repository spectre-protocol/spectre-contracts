# Spectre Protocol - Integration Test Summary

**Date:** February 2, 2026
**Network:** Unichain Sepolia (Chain ID: 1301)
**Status:** All Tests Passed

---

## Test Results

### On-Chain Private Swap (Foundry)

```
================================================================
              PRIVATE SWAP SUCCESSFUL!
================================================================

Swap Results:
  Token A spent: 1000
  Token B received: 986.86

Privacy Features Applied:
  [x] Ring signature verified (sender hidden among 5)
  [x] Key image recorded (prevents double-spend)
  [x] Stealth address generated (recipient hidden)
  [x] ERC-5564 announcement emitted

Check SpectreHook stats:
  Total private swaps: 1
  Key image used: true
```

### SDK + Contract Integration (TypeScript)

```
SDK Functions Tested:
  ✅ generateStealthKeys() - Created recipient privacy keys
  ✅ generateRingSignature() - Created LSAG ring signature
  ✅ encodeHookData() - Encoded data for contract

On-Chain Contracts Tested:
  ✅ StealthRegistry.registerStealthMetaAddress()
  ✅ StealthRegistry.generateStealthAddress()
  ✅ Announcer.announce()
```

---

## Deployed Contracts (Unichain Sepolia)

| Contract | Address |
|----------|---------|
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| StealthRegistry | `0xA9e4ED4183b3B3cC364cF82dA7982D5ABE956307` |
| Announcer | `0x42013A72753F6EC28e27582D4cDb8425b44fd311` |
| RingVerifier | `0x6A150E2681dEeb16C2e9C446572087e3da32981E` |
| SpectreHook | `0x1Fff852F99d79c1B504A7Da299Cd1E4feb2c40c4` |

---

## SDK Usage for Frontend

### Installation

```bash
cd spectre-sdk
npm install
npm run build
```

### Basic Usage

```typescript
import {
  generateStealthKeys,
  generateRingSignature,
  encodeHookData,
  UNICHAIN_SEPOLIA,
} from '@spectre/sdk';

// 1. Generate recipient's stealth keys (one-time setup)
const recipientKeys = generateStealthKeys();
console.log('Meta-address:', recipientKeys.stealthMetaAddress);

// 2. Create ring signature (hides sender among decoys)
const { signature, keyImage } = generateRingSignature({
  message: swapMessageHash,      // keccak256 of swap params
  privateKey: userPrivateKey,    // User's private key
  publicKeys: ringMembers,       // Array of 5-10 addresses (decoys + signer)
  signerIndex: 0,                // Position of real signer in ring
});

// 3. Encode hook data for the swap
const hookData = encodeHookData({
  ringSignature: signature,
  keyImage,
  ringMembers,
  stealthMetaAddress: recipientKeys.stealthMetaAddress,
});

// 4. Execute swap with hookData
// Pass hookData to Uniswap v4 swap call via PoolSwapTest or router
```

### Scanning for Incoming Transfers

```typescript
import { checkStealthAddress, deriveStealthPrivateKey } from '@spectre/sdk';

// Check if an announcement is for you
const isForMe = checkStealthAddress({
  stealthAddress: announcedAddress,
  ephemeralPubKey: announcement.ephemeralPubKey,
  spendingKey: recipientKeys.spendingPrivateKey,
  viewingKey: recipientKeys.viewingPrivateKey,
});

if (isForMe) {
  // Derive the private key to control the stealth address
  const stealthPrivateKey = deriveStealthPrivateKey({
    ephemeralPubKey: announcement.ephemeralPubKey,
    spendingKey: recipientKeys.spendingPrivateKey,
    viewingKey: recipientKeys.viewingPrivateKey,
  });
}
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        SPECTRE PROTOCOL                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐ │
│  │   Frontend  │───▶│  SDK        │───▶│  Smart Contracts    │ │
│  │   (React)   │    │  (TS/Viem)  │    │  (Solidity)         │ │
│  └─────────────┘    └─────────────┘    └─────────────────────┘ │
│                                                                 │
│  SDK Functions:                     Contracts:                  │
│  • generateStealthKeys()            • SpectreHook (Uni v4)     │
│  • generateRingSignature()          • RingVerifier (LSAG)      │
│  • encodeHookData()                 • StealthRegistry          │
│  • checkStealthAddress()            • Announcer (ERC-5564)     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

Privacy Flow:
1. Sender creates ring signature (hidden among decoys)
2. SpectreHook verifies signature in beforeSwap
3. Uniswap v4 executes the swap
4. SpectreHook generates stealth address in afterSwap
5. ERC-5564 announcement emitted for recipient to scan
6. Recipient derives private key to claim funds
```

---

## Test Scripts

### Run SDK Integration Test
```bash
cd spectre-sdk
PRIVATE_KEY=0x... npx tsx scripts/executeOnChainSwap.ts
```

### Run Full Private Swap Test (Foundry)
```bash
cd spectre-contracts
PRIVATE_KEY=0x... forge script script/ExecutePrivateSwap.s.sol:ExecutePrivateSwap \
  --rpc-url https://sepolia.unichain.org --broadcast -vvv
```

---

## Transaction Examples

- **Stealth Registration:** [View on Blockscout](https://unichain-sepolia.blockscout.com)
- **Private Swap:** Check broadcast folder for transaction hashes

---

## Notes for Frontend Team

1. **Ring Members**: For demo, use any 5 valid Ethereum addresses. In production, these should be real addresses with transaction history for better anonymity.

2. **Stealth Meta-Address**: This is a 66-byte value (33 bytes spending pubkey + 33 bytes viewing pubkey). Store securely - it's used to receive private payments.

3. **Key Image**: Unique per private key + message. Prevents double-spending. Once used, cannot be reused.

4. **Hook Data**: Must be passed to the swap function. Without it, the swap executes as a regular (non-private) swap.

5. **Scanning Announcements**: The recipient must scan ERC-5564 `Announcement` events to discover incoming transfers.
