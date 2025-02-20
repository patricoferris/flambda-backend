[@@@ocaml.warning "+a-4-30-40-41-42"]

open! Int_replace_polymorphic_compare

module type Domain = sig
  type t

  val top : t

  val bot : t

  val compare : t -> t -> int

  val join : t -> t -> t

  val to_string : t -> string
end

module type Transfer = sig
  type domain

  type t =
    { normal : domain;
      exceptional : domain
    }

  val basic : domain -> Cfg.basic Cfg.instruction -> t

  val terminator : domain -> Cfg.terminator Cfg.instruction -> t
end

module type S = sig
  type domain

  type map = domain Label.Tbl.t

  val run :
    Cfg.t -> ?max_iteration:int -> ?init:domain -> unit -> (map, map) Result.t
end

module Forward (D : Domain) (T : Transfer with type domain = D.t) :
  S with type domain = D.t = struct
  type domain = D.t

  type transfer = T.t

  type map = domain Label.Tbl.t

  module WorkSetElement = struct
    type t =
      { label : Label.t;
        value : domain
      }

    let compare { label = left_label; value = left_value }
        { label = right_label; value = right_value } =
      match Label.compare left_label right_label with
      | 0 -> D.compare left_value right_value
      | res -> res
  end

  module WorkSet = Set.Make (WorkSetElement)

  let transfer_block : domain -> Cfg.basic_block -> transfer =
   fun value block ->
    let transfer f (acc_normal, acc_exceptional) instr =
      let { T.normal; exceptional } = f acc_normal instr in
      normal, D.join exceptional acc_exceptional
    in
    let normal, exceptional =
      transfer T.terminator
        (ListLabels.fold_left block.body ~init:(value, value)
           ~f:(transfer T.basic))
        block.terminator
    in
    { normal; exceptional }

  let create : Cfg.t -> init:domain option -> map * WorkSet.t ref =
   fun cfg ~init ->
    let map = Label.Tbl.create (Label.Tbl.length cfg.Cfg.blocks) in
    let set = ref WorkSet.empty in
    let value = Option.value init ~default:D.top in
    (* The need to have several blocks in the initial work set stems from the
       fact that we currently need to consider all trap handlers as alive. *)
    Cfg.iter_blocks cfg ~f:(fun label block ->
        if Label.equal label cfg.entry_label || block.is_trap_handler
        then set := WorkSet.add { WorkSetElement.label; value } !set);
    map, set

  let remove_and_return :
      Cfg.t -> WorkSet.t ref -> WorkSetElement.t * Cfg.basic_block =
   fun cfg set ->
    let element = WorkSet.choose !set in
    set := WorkSet.remove element !set;
    element, Cfg.get_block_exn cfg element.label

  let run :
      Cfg.t -> ?max_iteration:int -> ?init:domain -> unit -> (map, map) Result.t
      =
   fun cfg ?(max_iteration = max_int) ?init () ->
    let res, work_set = create cfg ~init in
    let iteration = ref 0 in
    while (not (WorkSet.is_empty !work_set)) && !iteration < max_iteration do
      incr iteration;
      let element, block = remove_and_return cfg work_set in
      let ({ normal; exceptional } : T.t) =
        transfer_block element.value block
      in
      let update ~normal ~exn value =
        Label.Set.iter
          (fun successor_label ->
            let old_value =
              Option.value
                (Label.Tbl.find_opt res successor_label)
                ~default:D.bot
            in
            let new_value = D.join old_value value in
            if not (D.compare new_value old_value <= 0)
            then begin
              Label.Tbl.replace res successor_label new_value;
              work_set
                := WorkSet.add
                     { WorkSetElement.label = successor_label;
                       value = new_value
                     }
                     !work_set
            end)
          (Cfg.successor_labels ~normal ~exn block)
      in
      update ~normal:true ~exn:false normal;
      update ~normal:false ~exn:true exceptional
    done;
    if !iteration < max_iteration then Result.Ok res else Result.Error res
end
