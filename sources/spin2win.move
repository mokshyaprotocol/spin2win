module spin2win::spin {
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::aptos_account;

    /// Caller of transaction is not the admin of the contract
    const EINVALID_SIGNER: u64 = 0;

    const PRIZE_TYPE_COIN: u8 = 0;
    const PRIZE_TYPE_TOKEN: u8 = 1;
    const PRIZE_TYPE_NFT: u8 = 2;
    const PRIZE_TYPE_POINTS: u8 = 3;

    struct Prize has store,drop{
        prize_type: u8, // Represents the type of prize (COIN, TOKEN, NFT, POINTS)
        value: u64, // Could represent amount for COIN/TOKEN/POINTS or ID for NFT
        token_address: address, // Only relevant for TOKEN or NFT
        collection_address: address, // Only relevant for NFTs, specifies the collection
        probability: u64, // Probability of winning this prize
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct SpinEvents has key{
        event: EventHandle<SpinEvent>,
    }

    struct PrizePool has key,store{
        prizes: vector<Prize>, 
        cumulative_probabilities: vector<u64>, // Cumulative probabilities corresponding to each prize
    }

    struct SpinEvent has drop, store {
        spinner: address,
        prize_type: u8,
        value: u64,
        token_address: address,
        collection_address: address,
        probability: u64,
    }


    fun init_module(account: &signer) {
        let constructor_ref = object::create_object_from_account(account);
        let object_signer = object::generate_signer(&constructor_ref);
        let event_handle = SpinEvents{
            event: object::new_event_handle(&object_signer)
        };

        let prize_pool = PrizePool {
            prizes: vector[],
            cumulative_probabilities: vector[],
        };

        move_to(account, event_handle);
        move_to(account, prize_pool);
    }

    public fun add_prize<CoinType>(
        account: &signer, 
        prize_type: u8, 
        value: u64, 
        token_address: address, 
        collection_address: address, 
        probability: u64
    ) acquires PrizePool {
        let pool = borrow_global_mut<PrizePool>(signer::address_of(account));
        
        // Handle prize data in a simpler manner, possibly storing them outside the resource.
        let prize = Prize {
            prize_type,
            value,
            token_address,
            collection_address,
            probability,
        };
        
        vector::push_back(&mut pool.prizes, prize);

        // Update the cumulative probabilities based on the new prize.
        update_cumulative_probabilities(pool, probability);
    }

    fun update_cumulative_probabilities(pool: &mut PrizePool, new_probability: u64) {
        let sum = if (vector::length(&pool.cumulative_probabilities) > 0) {
            *vector::borrow(&pool.cumulative_probabilities, vector::length(&pool.cumulative_probabilities) - 1)
        } else {
            0
        };
        vector::push_back(&mut pool.cumulative_probabilities, sum + new_probability);
    }

        // Function to distribute the prize based on its type
    fun distribute_prize<CoinType>(
        account: &signer, 
        prize_type: u8, 
        value: u64, 
        token_address: address, 
        collection_address: address
    ) {
        if (prize_type == PRIZE_TYPE_COIN) {
            aptos_account::transfer_coins<CoinType>(purchaser, fee_address, fee);
        } else if (prize_type == PRIZE_TYPE_TOKEN) {
            distribute_token(account, token_address, value);
        } else if (prize_type == PRIZE_TYPE_NFT) {
            distribute_nft(account, collection_address, token_address, value);
        } else if (prize_type == PRIZE_TYPE_POINTS) {
            distribute_points(account, value);
        }
    }
    fun distribute_coin(account: &signer, amount: u64) {
        AptosCoin::transfer(account, Signer::address_of(account), amount);
    }
}