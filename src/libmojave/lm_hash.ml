
(* %%MAGICBEGIN%% *)
type 'a marshal_item =
   { mutable item_ref : unit ref;
     mutable item_val : 'a;
     item_hash        : int
   }
(* %%MAGICEND%% *)
(*
 * A version with two equalities.
 * The fine equality is used for cons-hashing, but the coarse
 * version is used for external comparisons.  The fine equality
 * must be a refinement of the coarse equality.
 *)
(* %%MAGICBEGIN%% *)
type 'a marshal_eq_item = ('a * 'a marshal_item) marshal_item
(* %%MAGICEND%% *)

(*
 * Statistics.
 *)
type stat =
   { debug              : string;
     mutable reintern   : int;
     mutable compare    : int;
     mutable collisions : int
   }


(*
 * The reference in the current process.
 *)
let current_ref = ref ()

let stats = ref []

let pp_print_stat buf ({ debug      = debug;
         reintern   = reintern;
         compare    = compare;
         collisions = collisions
       } : stat) =
      Format.fprintf buf "@[<hv 3>%s: reintern = %d, compare = %d, collisions = %d@]@\n" (**)
         debug reintern compare collisions

let pp_print_stats buf =
   List.iter (pp_print_stat buf) !stats

(*
 * let () =
 *    at_exit (fun () -> pp_print_stats stderr)
 *)

(*
 * We need to work nicely with threads.
 *
 * Note that the reintern function may be recursive, so we need to account for cases,
 * where the current thread is already holding the lock.
 * Almost every accesses come from the main thread with very little if any contention from other
 * threads. This makes it more effiecient to use a single global lock (as opposed to having a
 * separate lock for each instance of the functor), so that mutually recursive reintern calls only
 * have to lock one lock, not all of them.
 *
 * Finally, we do not care about race conditions for the statistics
 *)
module Synchronize : sig
   val synchronize : ('a -> 'b) -> 'a -> 'b
end = struct
   let lock_mutex = Lm_thread_core.MutexCore.create "Lm_hash.Synchronize"
   let lock_id = ref None

   let unsynchronize () =
      lock_id := None;
      Lm_thread_core.MutexCore.unlock lock_mutex

   let synchronize f x =
      let id = Lm_thread_core.ThreadCore.id (Lm_thread_core.ThreadCore.self ()) in
         match !lock_id with
            Some id' when id = id' ->
               (*
                * We are already holding the lock. This means:
                *  - we do not have to do anything special
                *  - reading the shared lock_id ref could not have created a race condition
                *)
               f x
          | _ ->
               Lm_thread_core.MutexCore.lock lock_mutex;
               lock_id := Some id;
               try
                  let res = f x in
                     unsynchronize();
                     res
               with exn ->
                  unsynchronize();
                  raise exn
end

let synchronize =
   if Lm_thread_core.ThreadCore.enabled then
      Synchronize.synchronize
   else
      (fun f -> f)


module type MARSHAL = 
sig
  type t

  (* For debugging *)
  val debug : string

  (* The client needs to provide hash and comparison functions *)
  val hash : t -> int
  val compare : t -> t -> int
  val reintern : t -> t
end

module type MARSHAL_EQ = 
sig
   type t

   (* For debugging *)
   val debug : string

   (*
    * The client needs to provide the hash and the two comparison functions.
    *)
   val fine_hash      : t -> int
   val fine_compare   : t -> t -> int

   val coarse_hash    : t -> int
   val coarse_compare : t -> t -> int

   (* Rehash the value *)
   val reintern       : t -> t

end

(*
 * This is what we get.
 *)
module type HashMarshalSig =
sig
   type elt
   type t

   (* Creation *)
   val create   : elt -> t

   (* The intern function fails with Not_found if the node does not already exist *)
   val intern   : elt -> t

   (* Destructors *)
   val get      : t -> elt
   val hash     : t -> int

   (* Comparison *)
   val equal    : t -> t -> bool
   val compare  : t -> t -> int

   (* Rehash the value *)
   val reintern : t -> t
end

module type HashMarshalEqSig =
sig
   include HashMarshalSig (* The default equality is the coarse one *)

   val fine_hash    : t -> int
   val fine_compare : t -> t -> int
   val fine_equal   : t -> t -> bool
end

(*
 * Make a hash item.
 *)
module MakeHashMarshal (Arg : MARSHAL)=
struct
   type elt = Arg.t
   type t = elt marshal_item

   (* Keep a hash-cons table based on a weak comparison *)
   module WeakCompare =
   struct
      type t = elt marshal_item

      let compare item1 item2 =
         let hash1 = item1.item_hash in
         let hash2 = item2.item_hash in
            if hash1 < hash2 then
               -1
            else if hash1 > hash2 then
               1
            else
               Arg.compare item1.item_val item2.item_val
   end;;

   module Table = Lm_map.LmMake (WeakCompare);;

   let table = ref Table.empty

   (*
    * Keep track of collisions for debugging.
    *)
   let stat =
      { debug       = Arg.debug;
        reintern    = 0;
        compare     = 0;
        collisions  = 0
      }

   let () =
      stats := stat :: !stats

   (*
    * When creating an item, look it up in the table.
    *)
   let create_core elt =
      let item =
         { item_ref  = current_ref;
           item_val  = elt;
           item_hash = Arg.hash elt
         }
      in
         try Table.find !table item with
            Not_found ->
               table := Table.add !table item item;
               item

   let create = synchronize create_core

   let intern elt =
      let item =
         { item_ref  = current_ref;
           item_val  = elt;
           item_hash = Arg.hash elt
         }
      in
         Table.find !table item

   (*
    * Reintern.  This will take an item that may-or-may-not be hashed
    * and produce a new one that is hashed.
    *)
   let reintern_core item1 =
      stat.reintern <- succ stat.reintern;
      try
         let item2 = Table.find !table item1 in
            if item2 != item1 then begin
               item1.item_val <- item2.item_val;
               item1.item_ref <- current_ref
            end;
            item2
      with
         Not_found ->
            item1.item_val <- Arg.reintern item1.item_val;
            item1.item_ref <- current_ref;
            table := Table.add !table item1 item1;
            item1

   let reintern = synchronize reintern_core

   (*
    * Access to the element.
    *)
   let get item =
      if item.item_ref == current_ref then
         item.item_val
      else
         (reintern item).item_val

   let hash item =
      item.item_hash

   (*
    * String pointer-based comparison.
    *)
   let compare item1 item2 =
      stat.compare <- succ stat.compare;
      let hash1 = item1.item_hash in
      let hash2 = item2.item_hash in
         if hash1 < hash2 then
            -1
         else if hash1 > hash2 then
            1
         else if item1.item_val == item2.item_val then
            0
         else
            let elt1 = get item1 in
            let elt2 = get item2 in
               if elt1 == elt2 then
                  0
               else begin
                  stat.collisions <- succ stat.collisions;
                  let cmp = Arg.compare elt1 elt2 in
                     if cmp = 0 then
                        invalid_arg "Lm_hash is broken@.";
                     cmp
               end

   let equal item1 item2 =
      (item1 == item2) || (item1.item_hash = item2.item_hash && get item1 == get item2)
end


module MakeHashMarshalEq (Arg : MARSHAL_EQ) =
struct
   type elt = Arg.t
   type t = elt marshal_eq_item

   module CoarseArg =
   struct
      type t     = Arg.t
      let debug  = Arg.debug ^ ":coarse"

      let hash     = Arg.coarse_hash
      let compare  = Arg.coarse_compare
      let reintern = Arg.reintern
   end;;

   module Coarse = MakeHashMarshal (CoarseArg);;

   (*
    * We fold the Coarse item into the fine
    * item only so we don't have to create three
    * modules (the final one being a pair of fine
    * and coarse).
    *)
   module FineArg =
   struct
      type t     = Arg.t * Coarse.t
      let debug  = Arg.debug ^ ":fine"

      (*
       * We're assuming that the fine hash is a
       * refinement of the coarse one.
       *)
      let hash (fine, _) =
         Arg.fine_hash fine

      let compare (fine1, _) (fine2, _) =
         Arg.fine_compare fine1 fine2

      let reintern ((fine, coarse) as item) =
         let fine' = Arg.reintern fine in
         let coarse' = Coarse.reintern coarse in
            if fine' == fine && coarse' == coarse then
               item
            else
               fine', coarse'
   end;;

   module Fine = MakeHashMarshal (FineArg);;

   let create x =
      Fine.create (x, Coarse.create x)

   let intern x =
      Fine.intern (x, Coarse.intern x)

   let get info =
      fst (Fine.get info)

   (*
    * The default functions are the coarse versions.
    *)
   let get_coarse info =
      snd (Fine.get info)

   let hash info =
      Coarse.hash (get_coarse info)

   let compare item1 item2 =
      Coarse.compare (get_coarse item1) (get_coarse item2)

   let equal item1 item2 =
      Coarse.equal (get_coarse item1) (get_coarse item2)

   (*
    * Also export the fine versions.
    *)
   let fine_hash = Fine.hash
   let fine_compare = Fine.compare
   let fine_equal = Fine.equal

   let reintern = Fine.reintern
end
