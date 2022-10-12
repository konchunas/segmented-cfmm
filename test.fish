#!/opt/homebrew/bin/fish

alias mockup-client='tezos-client --mode mockup --base-dir /tmp/mockup'

function chosen_ligo
    docker run -v $PWD:$PWD --rm -i ligolang/ligo:0.35.0 $argv
    # ligo $argv
end

function contract_address
    mockup-client show known contract $argv
end

set far_future_deadline 1868629400

set alice "tz1ddb9NMYHZi5UzPdzTZMYQQZoMub195zgv" # bootstrap5
set bob "tz1b7tUupMgCNw2cCLpKTkSD1NZzB5TkP2sv" # bootstrap4
set admin "tz1faswCTDciRzE4oJ9jn2Vm2dvjeyA9fUzU" # bootstrap3

### TOKEN CREATION ###
set token_storage_ligo "record [
  ledger         = (Big_map.empty : big_map(address, account));
  token_info     = (Big_map.empty : big_map(token_id, token_info));
  metadata       = (Big_map.empty : big_map(string, bytes));
  token_metadata = (Big_map.empty : big_map(token_id, token_metadata_info));
  minters        = (Set.empty : set(address));
  admin          = (\"$admin\" : address);
  pending_admin  = (\"tz1burnburnburnburnburnburnburjAYjjX\" : address);
  last_token_id  = 0n;
]"

set token_storage_m (chosen_ligo compile storage $PWD/test_fa2_token.ligo  (echo $token_storage_ligo | string collect))
chosen_ligo compile contract $PWD/test_fa2_token.ligo > test_fa2_token.tz

mockup-client originate contract token_a transferring 1 from bootstrap1 \
                        running ./test_fa2_token.tz \
                        --init (echo $token_storage_m | string collect) --burn-cap 10 --force

set token_a_address (contract_address token_a | string collect)

mockup-client originate contract token_b transferring 1 from bootstrap1 \
                        running ./test_fa2_token.tz \
                        --init (echo $token_storage_m | string collect) --burn-cap 10 --force

set token_b_address (contract_address token_b | string collect)

### Create and mint A and B tokens ###

mockup-client transfer 0 from $admin to token_a --entrypoint "create_token" --arg "{}" --burn-cap 1
mockup-client transfer 0 from $admin to token_b --entrypoint "create_token" --arg "{}" --burn-cap 1

mockup-client transfer 0 from $admin to token_a --entrypoint "mint_asset" --arg "{Pair 0 \"$admin\" 10000000000}"  --burn-cap 1
mockup-client transfer 0 from $admin to token_b --entrypoint "mint_asset" --arg "{Pair 0 \"$admin\" 10000000000}"  --burn-cap 1

### Segmented CFMM ###

# replace token_a and token_b addresses to newly deployed in the default storage
set segmented_cfmm_storage_m (sed "1,1s/KT1PWx2mnDueood7fEmfbBDKx1D9BAnnXitn/$token_a_address/g;2,2s/KT1PWx2mnDueood7fEmfbBDKx1D9BAnnXitn/$token_b_address/g" out/storage_default.tz)

mockup-client originate contract segmented_cfmm transferring 1 from bootstrap1 \
                        running ./out/segmented_cfmm_default.tz \
                        --init (echo $segmented_cfmm_storage_m | string collect) --burn-cap 10 --force

set segmented_cfmm_address (contract_address segmented_cfmm | string collect)

### Initial Approvals ###

set add_operator_token_a_m (chosen_ligo compile expression pascaligo --init-file $PWD/test_fa2_token.ligo "list [Add_operator(record [
  owner = (\"$admin\" : address);
  operator = (\"$segmented_cfmm_address\" : address);
  token_id = 0n;
])]")

mockup-client transfer 0 from $admin to token_a --entrypoint "update_operators" --arg "$add_operator_token_a_m" --burn-cap 1
mockup-client transfer 0 from $admin to token_b --entrypoint "update_operators" --arg "$add_operator_token_a_m" --burn-cap 1

### Set position ###

set set_position_m (chosen_ligo compile expression cameligo --init-file $PWD/ligo/main.mligo "{lower_tick_index = {i = -1048575}; upper_tick_index = {i = 1048575}; lower_tick_witness = {i = -1048575}; upper_tick_witness = {i = 1048575}; liquidity = 10000n; deadline = (\"2035-01-01t10:10:10Z\" : timestamp); maximum_tokens_contributed = { x = 100000n; y = 100000n }}")

mockup-client transfer 0 from $admin to segmented_cfmm --entrypoint "set_position" --arg "$set_position_m" --burn-cap 1

### X to Y swap ###
set x_to_y_m (chosen_ligo compile expression cameligo --init-file $PWD/ligo/main.mligo "{
    dx = 1_000n;
    deadline = (\"2035-01-01t10:10:10Z\" : timestamp);
    min_dy = 1n;
    to_dy = (\"$admin\" : address);
}")

echo $x_to_y_m

mockup-client transfer 0 from $admin to segmented_cfmm --entrypoint "x_to_y" --arg "$x_to_y_m" --burn-cap 1
exit 0

mockup-client transfer 0 from $alice to token --entrypoint "transfer" --arg "{ Pair \"$alice\" { Pair \"tz1faswCTDciRzE4oJ9jn2Vm2dvjeyA9fUzU\" (Pair 0 20) } }"  --burn-cap 1

mockup-client transfer 0 from $bob to token --entrypoint "transfer" --arg "{ Pair \"$bob\" { Pair \"tz1faswCTDciRzE4oJ9jn2Vm2dvjeyA9fUzU\" (Pair 0 200) } }"  --burn-cap 1
