//To-do 
// Remove prize from the prize struct on nft once the nft has been won 
module spin2win::spin {
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::object::{Self, Object,DeleteRef,TransferRef};
    use aptos_framework::aptos_account;
    use aptos_framework::account;
    use aptos_framework::randomness::{Self};
    use aptos_std::ed25519;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_token_objects::token::{Token};
    use aptos_token::token::{Self as tokenv1, Token as TokenV1};
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
        token_address: vector<address>, // Only relevant for TOKEN or NFT
        collection_address: address, // Only relevant for NFTs, specifies the collection
        probability: u64, // Probability of winning this prize
    }

    struct Spin has key,store,drop{
        prize_type: vector<u8>,
        nonce: u64,
        value: vector<u64>,
        token_address: vector<address>,
        collection_address: vector<address>,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct SpinEvents has key{
        event: EventHandle<SpinEvent>,
        claim_event: EventHandle<PrizeClaimEvent>,
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

    struct PrizeClaimEvent has drop, store {
        spinner: address,
        prize_type: vector<u8>,
        value: vector<u64>,
        token_address: vector<address>,
        collection_address: vector<address>,
    }
    /// Admin structure with administrative privileges
    struct Admin has key {
        admin: address,
        resource_cap: account::SignerCapability,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// Contains a tokenv1 as an object
    struct TokenV1Container has key {
        /// The stored token.
        token: TokenV1,
        /// Used to cleanup the object at the end
        delete_ref: DeleteRef,
        /// Used to transfer the tokenv1 at the conclusion of a purchase.
        transfer_ref: TransferRef,
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
            event: object::new_event_handle(&object_signer),
            claim_event: object::new_event_handle(&object_signer)
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
        token_address: vector<address>, 
        collection_address: address, 
        probability: u64
    ) acquires PrizePool {
        assert!(@spin2win == signer::address_of(account), EINVALID_SIGNER);
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
    entry fun spin<CoinType>(account: &signer,signature: vector<u8>,) acquires PrizePool, SpinEvents,Spin{
        let spinner_addr = signer::address_of(account);
        if (!exists<Spin>(spinner_addr)){
            let spin = Spin {
                prize_type: vector[],
                value: vector[],
                token_address: vector[],
                collection_address: vector[],
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
        let select_prize_token_address = *vector::borrow(&selected_prize.token_address, 0);
        let event_handle = borrow_global_mut<SpinEvents>(@spin2win);
        let spin_event = SpinEvent {
            spinner: spinner_addr,
            prize_type: selected_prize.prize_type,
            value: selected_prize.value,
            token_address: select_prize_token_address,
            collection_address: selected_prize.collection_address,
            probability: selected_prize.probability,
        };
        // let admin_info = borrow_global_mut<Admin>(@spin2win);
        // let admin = account::create_signer_with_capability(&admin_info.resource_cap);
        // distribute_prize<CoinType>(&admin,selected_prize.prize_type,selected_prize.value,select_prize_token_address,selected_prize.collection_address,spinner_addr);
        vector::push_back(&mut spin_info.prize_type , selected_prize.prize_type);
        vector::push_back(&mut spin_info.value , selected_prize.value);
        vector::push_back(&mut spin_info.token_address , select_prize_token_address);
        vector::push_back(&mut spin_info.collection_address , selected_prize.collection_address);
        spin_info.nonce = spin_info.nonce+1;
        event::emit_event(&mut event_handle.event,spin_event);
        vector::remove(&mut selected_prize.token_address, 0); 
    }

    entry fun claim_prizes<CoinType>(account: &signer,) acquires Spin,Admin,TokenV1Container,SpinEvents{
        let spinner_addr = signer::address_of(account);
        let spin_info = borrow_global_mut<Spin>(spinner_addr);
        let admin_info = borrow_global_mut<Admin>(@spin2win);
        let admin = account::create_signer_with_capability(&admin_info.resource_cap);
        let i = 0;
        while (i < vector::length(&spin_info.prize_type)){
            distribute_prize<CoinType>(&admin,*vector::borrow(&spin_info.prize_type, i),*vector::borrow(&spin_info.value, i),*vector::borrow(&spin_info.token_address, i),*vector::borrow(&spin_info.collection_address, i),spinner_addr);
            i=i+1
        };
        spin_info.prize_type =vector[];
        spin_info.value =vector[];
        spin_info.token_address =vector[];
        spin_info.collection_address =vector[];
        let event_handle = borrow_global_mut<SpinEvents>(@spin2win);
        let prize_claim_event = PrizeClaimEvent {
            spinner: spinner_addr,
            prize_type: spin_info.prize_type,
            value: spin_info.value,
            token_address: spin_info.token_address,
            collection_address: spin_info.collection_address,
        };
        event::emit_event(&mut event_handle.claim_event,prize_claim_event)
    }

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
    )acquires TokenV1Container{
        if (prize_type == PRIZE_TYPE_COIN && prize_type == PRIZE_TYPE_TOKEN) {
            distribute_coin<CoinType>(account, receiver, value);
        } else if (prize_type == PRIZE_TYPE_NFT) {
            distribute_nft(account, token_address,receiver);
        } else{
            distribute_coin<AptosCoin>(account, receiver, value);
        }
    }

    fun distribute_coin<CoinType>(account: &signer, receiver:address, amount: u64) {
        aptos_account::transfer_coins<CoinType>(account, receiver, amount);
    }

    fun distribute_nft(account: &signer,token_address:address,receiver:address)acquires TokenV1Container{
        if (exists<TokenV1Container>(token_address)){
            let TokenV1Container {
                token,
                delete_ref,
                transfer_ref: _,
            } = move_from(token_address);
            tokenv1::deposit_token(account, token);
            object::delete(delete_ref);
        }
        else{
            let object = object::address_to_object<Token>(token_address);
            object::transfer(account,object,receiver);
        }
    }

    public entry fun create_tokenv1_container(
        account: &signer,
        token_creator: address,
        token_collection: String,
        token_name: String,
        token_property_version: u64,
    ){
        assert!(@spin2win == signer::address_of(account), EINVALID_SIGNER);
        let token_id = tokenv1::create_token_id_raw(
            token_creator,
            token_collection,
            token_name,
            token_property_version,
        );
        let token = tokenv1::withdraw_token(account, token_id, 1);
        create_tokenv1_container_with_token(account, token)
    }

    fun create_tokenv1_container_with_token(
        account: &signer,
        token: TokenV1,
    ){
        let constructor_ref = object::create_object_from_account(account);
        let container_signer = object::generate_signer(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);

        move_to(&container_signer, TokenV1Container { token, delete_ref, transfer_ref });
    }
    public entry fun deposit_v1_nft(
        account: &signer,
        token_creator: address,
        token_collection: String,
        token_name: vector<String>,
        token_property_version: u64,
    ){
        let i = 0;
        while (i < vector::length(&token_name)){
            let name = *vector::borrow(&token_name, i);
            create_tokenv1_container(account,token_creator,token_collection,name,token_property_version);
            i=i+1
        }
    }
}