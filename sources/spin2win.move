module spin2win::spin {
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::aptos_account;
    use aptos_framework::account;
    use aptos_framework::randomness::{Self};
    use aptos_std::ed25519;
    use aptos_token_objects::token::{Token};
    use std::bcs;
    /// Caller of transaction is not the admin of the contract
    const EINVALID_SIGNER: u64 = 0;
    /// Signature is not signed by admin
    const ESIGNATURE_MISMATCHED: u64 =2;

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

    struct Spin has key,store,drop{
        nonce: u64
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

    /// Admin structure with administrative privileges
    struct Admin has key {
        admin: address,
        resource_cap: account::SignerCapability,
    }

    fun init_module(account: &signer) {
        let (_resource, resource_cap) = account::create_resource_account(account, x"02");
        let resource_signer_from_cap = account::create_signer_with_capability(&resource_cap);
        move_to<Admin>(account, Admin {
            admin: signer::address_of(account),
            resource_cap,
        });
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

    public entry fun add_prize<CoinType>(
        account: &signer, 
        prize_type: u8, 
        value: u64, 
        token_address: address, 
        collection_address: address, 
        probability: u64
    ) acquires PrizePool {
        let pool = borrow_global_mut<PrizePool>(@spin2win);
        
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

    #[randomness]
    entry fun spin<CoinType>(account: &signer,signature: vector<u8>,) acquires PrizePool, SpinEvents,Spin,Admin{
        let spinner_addr = signer::address_of(account);
        if (!exists<Spin>(spinner_addr)){
            let spin = Spin {
                nonce: 0
            };
            move_to(account, spin);
        };
        let spin_info = borrow_global_mut<Spin>(spinner_addr);
        let pool = borrow_global_mut<PrizePool>(@spin2win);
        let pk_bytes= x"6b8a589130ce4e558238d864b2c2a77f9e35dda290b98de9d2cb7490665c731f";
        let vpk = &ed25519::public_key_to_unvalidated(&std::option::extract(&mut ed25519::new_validated_public_key_from_bytes(pk_bytes)));
        let msg = bcs::to_bytes(&spinner_addr);
        vector::append(&mut msg, bcs::to_bytes(&spin_info.nonce));
        // Ensure that nonce is signed by admin
        assert!(ed25519::signature_verify_strict(&ed25519::new_signature_from_bytes(signature),&ed25519::public_key_to_unvalidated(&std::option::extract(&mut ed25519::new_validated_public_key_from_bytes(pk_bytes))), msg), ESIGNATURE_MISMATCHED);
        
        let max_prob = *vector::borrow(&pool.cumulative_probabilities, vector::length(&pool.cumulative_probabilities) - 1);
        let rand = randomness::u64_range(0, max_prob);
        let selected_prize_index = select_prize(&pool.cumulative_probabilities, rand);
        let selected_prize = vector::borrow(&pool.prizes, selected_prize_index);

        let event_handle = borrow_global_mut<SpinEvents>(@spin2win);
        let spin_event = SpinEvent {
            spinner: spinner_addr,
            prize_type: selected_prize.prize_type,
            value: selected_prize.value,
            token_address: selected_prize.token_address,
            collection_address: selected_prize.collection_address,
            probability: selected_prize.probability,
        };
        let admin_info = borrow_global_mut<Admin>(@spin2win);
        let admin = account::create_signer_with_capability(&admin_info.resource_cap);
        distribute_prize<CoinType>(&admin,selected_prize.prize_type,selected_prize.value,selected_prize.token_address,selected_prize.collection_address,spinner_addr);
        spin_info.nonce = spin_info.nonce+1;
        event::emit_event(&mut event_handle.event,spin_event)
    }

    entry
    fun select_prize(cumulative_probabilities: &vector<u64>, rand: u64): u64 {
        for (i in 0..vector::length(cumulative_probabilities)) {
            if (rand < *vector::borrow(cumulative_probabilities, i)) {
                return i
            }
        };
        return 0 // Default to the first prize if something goes wrong
    }

    // Function to distribute the prize based on its type
    fun distribute_prize<CoinType>(
        account: &signer, 
        prize_type: u8, 
        value: u64, 
        token_address: address, 
        collection_address: address,
        receiver: address
    ) {
        if (prize_type == PRIZE_TYPE_COIN || prize_type == PRIZE_TYPE_TOKEN) {
            distribute_coin<CoinType>(account, receiver, value);
        } else if (prize_type == PRIZE_TYPE_NFT) {
            distribute_nft(account, token_address,receiver);
        }
    }

    fun distribute_coin<CoinType>(account: &signer, receiver:address, amount: u64) {
        aptos_account::transfer_coins<CoinType>(account, receiver, amount);
    }

    fun distribute_nft(account: &signer,token_address:address,receiver:address){
        let object = object::address_to_object<Token>(token_address);
        object::transfer(account,object,receiver);
        // token::transfer(&admin,token_address,receiver,1)
    }
}