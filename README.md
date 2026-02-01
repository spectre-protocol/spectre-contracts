# Spectre Contracts

> The Invisible Hand of DeFi - Privacy-preserving swaps on Uniswap v4

Smart contracts for Spectre Protocol, enabling private token swaps through ring signatures and stealth addresses on Unichain.

## Overview

Spectre is the first privacy-preserving DEX built on Uniswap v4, combining:
- **Ring Signatures (LSAG)** - Hide sender identity among a group of addresses
- **Stealth Addresses (ERC-5564)** - Generate unlinkable recipient addresses
- **Uniswap v4 Hooks** - Seamless integration with Uniswap liquidity

## Contracts

| Contract | Description |
|----------|-------------|
| `SpectreHook.sol` | Main Uniswap v4 hook - verifies privacy proofs and routes outputs |
| `RingVerifier.sol` | LSAG ring signature verification |
| `StealthAddressRegistry.sol` | Stealth meta-address registration and generation |
| `ERC5564Announcer.sol` | ERC-5564 payment announcement events |
                                                                                                                                                
                                                                                                                                                                           
  Deployment Summary                                                                                                                                                       
  ┌────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────┐                                                  
  │        Contract        │                                          Address                                           │                                                  
  ├────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤                                                  
  │ SpectreHook            │ https://unichain-sepolia.blockscout.com/address/0x1D508fABBff9Cb22746Fe56dB763F58F384bCd38 │                                                  
  ├────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤                                                  
  │ RingVerifier           │ https://unichain-sepolia.blockscout.com/address/0x6A150E2681dEeb16C2e9C446572087e3da32981E │                                                  
  ├────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤                                                  
  │ StealthAddressRegistry │ https://unichain-sepolia.blockscout.com/address/0xA9e4ED4183b3B3cC364cF82dA7982D5ABE956307 │                                                  
  ├────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤                                                  
  │ ERC5564Announcer       │ https://unichain-sepolia.blockscout.com/address/0x42013A72753F6EC28e27582D4cDb8425b44fd311 │                                                  
  └────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────┘                                                                                                                

## Installation

```bash
# Clone the repository
git clone https://github.com/spectre-protocol/spectre-contracts
cd spectre-contracts

# Install dependencies
forge install

# Copy environment file
cp .env.example .env
# Edit .env with your keys
```

## Build

```bash
forge build
```

## Test

```bash
forge test -vvv
```

## Deployment

### Unichain Sepolia (Testnet)

```bash
forge script script/Deploy.s.sol:DeploySpectre \
    --rpc-url $UNICHAIN_SEPOLIA_RPC \
    --broadcast \
    --verify
```

### Unichain Mainnet

```bash
forge script script/Deploy.s.sol:DeploySpectre \
    --rpc-url $UNICHAIN_MAINNET_RPC \
    --broadcast \
    --verify
```

## Network Configuration

| Network | Chain ID | RPC | Explorer |
|---------|----------|-----|----------|
| Unichain Sepolia | 1301 | https://sepolia.unichain.org | https://sepolia.uniscan.xyz |
| Unichain Mainnet | 130 | https://mainnet.unichain.org | https://uniscan.xyz |

## Architecture

```
User → SDK (generates ring sig + stealth addr) → SpectreHook
                                                      │
                                                      ├── beforeSwap: verify ring signature
                                                      │
                                                      ├── [Uniswap swap executes]
                                                      │
                                                      └── afterSwap: route to stealth address
```

# Integration Test Summary                                                                                                                                                 
                                                                                                                                                                           
  3 Transactions Executed on Unichain Sepolia:                                                                                                                             
  #: 1                                                                                                                                                                     
  Function: registerStealthMetaAddress                                                                                                                                     
  Contract: StealthAddressRegistry                                                                                                                                         
  Tx Hash: https://unichain-sepolia.blockscout.com/tx/0x6f4a0b7a6c83994efa334527b4a95322a92e9aae6fcb5c37efcce62fc3aa26b1                                                   
  ────────────────────────────────────────                                                                                                                                 
  #: 2                                                                                                                                                                     
  Function: generateStealthAddress                                                                                                                                         
  Contract: StealthAddressRegistry                                                                                                                                         
  Tx Hash: https://unichain-sepolia.blockscout.com/tx/0x783837e9ee01398a786dbefc6b4216b993e89690602a4c50533d6fb4e4692d1f                                                   
  ────────────────────────────────────────                                                                                                                                 
  #: 3                                                                                                                                                                     
  Function: announce                                                                                                                                                       
  Contract: ERC5564Announcer                                                                                                                                               
  Tx Hash: https://unichain-sepolia.blockscout.com/tx/0x53d300183b30e1abf82e57ca504e72533469f91269a7d8697238d9c83e5e29d9                                                   
  Test Results                                                                                                                                                             
                                                                                                                                                                           
  === Test 1: SpectreHook Stats ===                                                                                                                                        
  Total private swaps: 0                                                                                                                                                   
  MIN_RING_SIZE: 2                                                                                                                                                         
  MAX_RING_SIZE: 10                                                                                                                                                        
                                                                                                                                                                           
  === Test 2: Register Stealth Meta-Address ===                                                                                                                            
  Meta-address length: 66 bytes ✓                                                                                                                                          
                                                                                                                                                                           
  === Test 3: Generate Stealth Address ===                                                                                                                                 
  Stealth address: 0xbB9149F6a9F685e58B008626293788FaFDc879b9 ✓                                                                                                            
  Ephemeral pubkey: 33 bytes ✓                                                                                                                                             
  View tag: 242 ✓                                                                                                                                                          
                                                                                                                                                                           
  === Test 4: Emit Announcement ===                                                                                                                                        
  ERC-5564 Announcement emitted ✓                                                                                                                                          
                                                                                                                                                                           
  === Test 5: RingVerifier Constants ===                                                                                                                                   
  MIN_RING_SIZE: 2 ✓                                                                                                                                                       
  MAX_RING_SIZE: 10 ✓               

## License

MIT

## Links

- **App**: https://spectre-protocol.vercel.app
- **SDK**: https://npmjs.com/package/@spectre-protocol/sdk
- **Docs**: https://github.com/spectre-protocol
