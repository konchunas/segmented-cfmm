// SPDX-FileCopyrightText: 2021 Arthur Breitman
// SPDX-License-Identifier: LicenseRef-MIT-Arthur-Breitman

#include "types.mligo"
#include "consts.mligo"
#include "helpers.mligo"
#include "transfers.mligo"
#include "math.mligo"
#include "swaps.mligo"

(* TODO: make positions into an FA2 *)

#if !DUMMY_PRAGMA1
This is an example of conditionally present code, remove it once normal pragmas are set.
#endif

let rec initialize_tick ((ticks, i, i_l,
    initial_fee_growth_outside,
    initial_seconds_outside,
    initial_seconds_per_liquidity_outside) : tick_map * tick_index * tick_index * balance_nat_x128 * nat * nat) : tick_map =
    if Big_map.mem i ticks then
        ticks
    else if i_l.i > i.i then
        (failwith invalid_witness_err : tick_map)
    else
        let tick = get_tick ticks i_l tick_not_exist_err in
        let i_next = tick.next in
        if i_next.i > i.i then
            let tick_next = get_tick ticks i_next internal_tick_not_exist_err in
            let ticks = Big_map.update i_l (Some {tick with next = i}) ticks in
            let ticks = Big_map.update i_next (Some {tick_next with prev = i}) ticks in
            let ticks = Big_map.update i (Some {
                prev = i_l ;
                next = i_next ;
                liquidity_net = 0 ;
                n_positions = 0n ;
                fee_growth_outside = initial_fee_growth_outside;
                seconds_outside = initial_seconds_outside;
                seconds_per_liquidity_outside = initial_seconds_per_liquidity_outside;
                sqrt_price = half_bps_pow i.i}) ticks in
            ticks
        else
            initialize_tick (ticks, i, i_next, initial_fee_growth_outside, initial_seconds_outside, initial_seconds_per_liquidity_outside)

let incr_n_positions (ticks : tick_map) (i : tick_index) (incr : int) =
    let tick = get_tick ticks i internal_tick_not_exist_err in
    let n_pos = assert_nat (tick.n_positions + incr, internal_position_underflow_err) in
    if n_pos = 0n then
        (*  Garbage collect the tick.
            The largest and smallest tick are initialized with n_positions = 1 so they cannot
            be accidentally garbage collected. *)
        let prev = get_tick ticks tick.prev internal_tick_not_exist_err in
        let next = get_tick ticks tick.next internal_tick_not_exist_err in
        (* prev links to next and next to prev, skipping the deleted tick *)
        let prev = {prev with next = tick.next} in
        let next = {next with prev = tick.prev} in
        let ticks = Big_map.update i (None : tick_state option) ticks in
        let ticks = Big_map.update tick.prev (Some prev) ticks in
        let ticks = Big_map.update tick.next (Some next) ticks in
        ticks
    else
        Big_map.update i (Some {tick with n_positions = n_pos}) ticks

let collect_fees (s : storage) (key : position_index) : storage * balance_nat =
    let position = match Big_map.find_opt key s.positions with
    | None -> (failwith "position does not exist" : position_state) // TODO: [TCFMM-16] This error is a bug.
    | Some position -> position in
    let tick_lo = get_tick s.ticks key.lower_tick_index internal_tick_not_exist_err in
    let tick_hi = get_tick s.ticks key.upper_tick_index internal_tick_not_exist_err in
    let f_a = if s.cur_tick_index >= key.upper_tick_index.i then
        { x = {x128 = assert_nat (s.fee_growth.x.x128 - tick_hi.fee_growth_outside.x.x128, internal_311)};
          y = {x128 = assert_nat (s.fee_growth.y.x128 - tick_hi.fee_growth_outside.y.x128, internal_311)}}
    else
        tick_hi.fee_growth_outside in
    let f_b = if s.cur_tick_index >= key.lower_tick_index.i then
        tick_lo.fee_growth_outside
    else
        { x = {x128 = assert_nat (s.fee_growth.x.x128 - tick_lo.fee_growth_outside.x.x128, internal_312)} ;
          y = {x128 = assert_nat (s.fee_growth.y.x128 - tick_lo.fee_growth_outside.y.x128, internal_312)} } in
    let fee_growth_inside = {
        x = {x128 = assert_nat (s.fee_growth.x.x128 - f_a.x.x128 - f_b.x.x128, internal_314)} ;
        y = {x128 = assert_nat (s.fee_growth.y.x128 - f_a.y.x128 - f_b.y.x128, internal_315)} } in
    let fees = {
        x = Bitwise.shift_right ((assert_nat (fee_growth_inside.x.x128 - position.fee_growth_inside_last.x.x128, internal_316)) * position.liquidity) 128n;
        y = Bitwise.shift_right ((assert_nat (fee_growth_inside.y.x128 - position.fee_growth_inside_last.y.x128, internal_317)) * position.liquidity) 128n} in
    let position = {position with fee_growth_inside_last = fee_growth_inside} in
    let positions = Big_map.update key (Some position) s.positions in
    ({s with positions = positions}, fees)


let set_position (s : storage) (i_l : tick_index) (i_u : tick_index) (i_l_l : tick_index) (i_u_l : tick_index) (liquidity_delta : int) (to_x : address) (to_y : address) : result =
    (* Initialize ticks if need be. *)
    let ticks = s.ticks in
    let ticks = if s.cur_tick_index >= i_l.i then
        initialize_tick (ticks, i_l, i_l_l, s.fee_growth, assert_nat (Tezos.now - epoch_time, internal_epoch_bigger_than_now_err), 42n (*FIXME*))
    else
        initialize_tick (ticks, i_l, i_l_l, {x = {x128 = 0n} ; y = {x128 = 0n}}, 0n, 0n)  in
    let ticks = if s.cur_tick_index >= i_u.i then
        initialize_tick (ticks, i_u, i_u_l, s.fee_growth, assert_nat (Tezos.now - epoch_time, internal_epoch_bigger_than_now_err), 42n (*FIXME*))
    else
        initialize_tick (ticks, i_u, i_u_l, {x = {x128 = 0n} ; y = {x128 = 0n}}, 0n, 0n)  in

    (* Form position key. *)
    let position_key = {owner=Tezos.sender ; lower_tick_index=i_l; upper_tick_index=i_u} in
    (* Grab existing position or create an empty one *)
    let (position, is_new) = match (Big_map.find_opt position_key s.positions) with
    | Some position -> (position, false)
    | None -> ({liquidity = 0n ; fee_growth_inside_last = {x = {x128 = 0n}; y = {x128 = 0n}}}, true) in
    (* Get accumulated fees for this position. *)
    let s, fees = collect_fees s position_key in
    (* Update liquidity of position. *)
    let liquidity_new = assert_nat (position.liquidity + liquidity_delta, internal_liquidity_below_zero_err) in
    let position = {position with liquidity = liquidity_new} in
    (* Reference counting the positions associated with a tick *)
    let ticks = (if liquidity_new = 0n then
        if is_new then
            ticks
        else
            let ticks = incr_n_positions ticks i_l (-1) in
            let ticks = incr_n_positions ticks i_u (-1) in
            ticks
    else
        if is_new then
            let ticks = incr_n_positions ticks i_l (1) in
            let ticks = incr_n_positions ticks i_u (1) in
            ticks
        else
            ticks) in
    (* delete the position if liquidity has fallen to 0 *)
    let position_entry : position_state option = if liquidity_new = 0n then None else Some {position with liquidity = liquidity_new} in
    let positions = Big_map.update position_key position_entry s.positions in
    (* Compute how much should be deposited / withdrawn to change liquidity by liquidity_net *)

    (* Grab cached prices for the interval *)
    let tick_u = get_tick ticks i_u internal_tick_not_exist_err in
    let tick_l = get_tick ticks i_l internal_tick_not_exist_err in
    let srp_u = tick_u.sqrt_price in
    let srp_l = tick_l.sqrt_price in

    (* Add or remove liquidity above the current tick *)
    let (s, delta) =
    if s.cur_tick_index < i_l.i then
        (s, {
            (* If I'm adding liquidity, x will be positive, I want to overestimate it, if x I'm taking away
                liquidity, I want to to underestimate what I'm receiving. *)
            x = ceildiv_int (liquidity_delta * (int (Bitwise.shift_left (assert_nat (srp_u.x80 - srp_l.x80, internal_sqrt_price_grow_err_1)) 80n))) (int (srp_l.x80 * srp_u.x80)) ;
            y = 0})
    else if i_l.i <= s.cur_tick_index && s.cur_tick_index < i_u.i then
        (* update interval we are in, if need be ... *)
        let s = {s with cur_tick_witness = if i_l.i > s.cur_tick_witness.i then i_l else s.cur_tick_witness ; liquidity = assert_nat (s.liquidity + liquidity_delta, internal_liquidity_below_zero_err)} in
        (s, {
            x = ceildiv_int (liquidity_delta * (int (Bitwise.shift_left (assert_nat (srp_u.x80 - s.sqrt_price.x80, internal_sqrt_price_grow_err_1)) 80n))) (int (s.sqrt_price.x80 * srp_u.x80)) ;
            y = shift_int (liquidity_delta * (s.sqrt_price.x80 - srp_l.x80)) (-80)
            })
    else (* cur_tick_index >= i_u *)
        (s, {x = 0 ; y = shift_int (liquidity_delta * (srp_u.x80 - srp_l.x80)) (-80) }) in

    (* Collect fees to increase withdrawal or reduce required deposit. *)
    let delta = {x = delta.x - fees.x ; y = delta.y - fees.y} in

    let op_x = if delta.x > 0 then
        x_transfer Tezos.sender Tezos.self_address (abs delta.x)
    else
        x_transfer Tezos.self_address to_x (abs delta.x) in

    let op_y = if delta.y > 0 then
        y_transfer Tezos.sender Tezos.self_address (abs delta.y)
    else
        y_transfer Tezos.self_address to_y (abs delta.y) in

    ([op_x ; op_y], {s with positions = positions; ticks = ticks})


type views =
    | IC_sum of int

let get_time_weighted_sum (s : storage) (c : views contract) : result =
    ([Tezos.transaction (IC_sum s.time_weighted_ic_sum) 0mutez c], s)

type parameter =
| X_to_Y of x_to_y_param
| Y_to_X of y_to_x_param
| Set_position of set_position_param (* TODO add deadline, maximum tokens contributed, and maximum liquidity present *)
| X_to_X_prime of address (* equivalent to token_to_token *)
| Get_time_weighted_sum of views contract

let update_time_weighted_sum (s : storage) : storage =
    let new_sum = s.time_weighted_ic_sum + (Tezos.now - s.last_ic_sum_update) * s.cur_tick_index
    in {s with time_weighted_ic_sum = new_sum ; last_ic_sum_update = Tezos.now}

let main ((p, s) : parameter * storage) : result =
(* start by updating the time weighted price oracle *)
let s = update_time_weighted_sum s in
(* dispatch call to the proper entrypoint *)
 match p with
| X_to_Y p -> x_to_y s p
| Y_to_X p -> y_to_x s p
| Set_position p -> set_position s p.lower_tick_index p.upper_tick_index p.lower_tick_witness p.upper_tick_witness p.liquidity_delta p.to_x p.to_y
| Get_time_weighted_sum contract -> get_time_weighted_sum s contract
| X_to_X_prime _ -> (failwith "not implemented" : result) (*TODO implement iff Y is FA12 *)
