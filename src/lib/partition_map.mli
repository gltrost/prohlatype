module Interval : sig

  type t

  val compare : t -> t -> int

  val max_value : int

  val make : start:int -> end_:int -> t

  val extend_one : t -> t

  val width : t -> int

  val inside : int -> t -> bool

  val start : t -> int

  val end_ : t -> int

  val to_string : t -> string

  val is_none : t -> bool

  val strict_before : t -> t -> bool

  val before_separate : t -> t -> bool

  val merge : t -> t -> t

  val split_inter_diff2 : t -> t ->
                          t * t * t * t * t
  val split_inter_diff3 : t -> t -> t ->
                          t * t * t * t * t * t * t
  val split_inter_diff4 : t -> t -> t -> t ->
                          t * t * t * t * t * t * t * t * t

  val aligned_inter_diff2 : t -> t ->
                            t * t * t
  val aligned_inter_diff3 : t -> t -> t ->
                            t * t * t * t
  val aligned_inter_diff4 : t -> t -> t -> t ->
                            t * t * t * t * t

  val fold : t -> init:'a -> f:('a -> int -> 'a) -> 'a

  val iter : t -> f:(int -> unit) -> unit

  val cpair : int -> t -> t -> t list

  val to_cross_indices : int -> t -> (int * int) list

end (* Interval *)

module Set : sig

  type t = Interval.t list

  (* Number of elements in the set. *)
  val size : t -> int

end (* Sig *)

(** A partition map is a data structure for a map over a partition of elements.

  Specifically, if we know (and specifically can enumerate) the elements of
  a set this data structure allows a mapping from elements to the values.
  Internally, it maintains partitions: representations of sets of the elements
  that partitions the entire universe. The most important operation is the
  {merge} of 2 (or more {merge4}) such partition maps.
*)

(* We construct partition map's in {descending} order then convert them
   into the {ascending} order for merging. *)
type ascending
type descending

type ('o, +'a) t

(* Empty constructors. *)
val empty_d : (descending, 'a) t
(* empty_a should only be used as a place holder (ex. initializing an array)
 * and not for computation. TODO: refactor this. *)
val empty_a : (ascending, 'a) t

(* Initializers. These take a value and either assume an entry (the 'first' one
   in the descending case) or all of them (pass the size of the partition, the
   resulting [t] has indices [[0,size)] ) in the ascending case. *)
val init_first_d : 'a -> (descending, 'a) t
val init_all_a : size:int -> 'a -> (ascending, 'a) t

val to_string : (_, 'a) t -> ('a -> string) -> string

(* Conversions. *)
val ascending : ('a -> 'a -> bool)
              -> (descending, 'a) t
              -> (ascending, 'a) t

(* Observe a value for the next element. *)
val add : 'a -> (descending, 'a) t -> (descending, 'a) t

(* [get t i] returns the value associated  with the [i]'th element.

   @raise {Not_found} if [i] is outside the range [0, (size t)). *)
val get : (ascending, 'a) t -> int -> 'a

(* Merge partition maps. Technically these are "map"'s but they are purposefully
  named merge since they're only implemented for {ascending} partition maps. *)
val merge : eq:('c -> 'c -> bool)
            -> (ascending, 'a) t
            -> (ascending, 'b) t
            -> ('a -> 'b -> 'c)
            -> (ascending, 'c) t

val merge3 : eq:('d -> 'd -> bool)
            -> (ascending, 'a) t
            -> (ascending, 'b) t
            -> (ascending, 'c) t
            -> ('a -> 'b -> 'c -> 'd)
            -> (ascending, 'd) t

(** [merge4] takes a specific {eq}uality predicate because it compreses new
    values generated by the mapping. When we compute a new value from the 4
    intersecting elements, we will scan an accumulator and add it if it is
    [not] equal to the other elements in the accumulator. Specifying, a good
    predicate for such an operation is important as it is intended to constrain
    the size of the final result. *)
val merge4 : eq:('e -> 'e -> bool)
            -> (ascending, 'a) t
            -> (ascending, 'b) t
            -> (ascending, 'c) t
            -> (ascending, 'd) t
            -> ('a -> 'b -> 'c -> 'd -> 'e)
            -> (ascending, 'e) t

(* Fold over the values. *)
val fold_values : (_, 'a) t
                -> init:'b
                -> f:('b -> 'a -> 'b)
                -> 'b

(* Fold over the values passing the underlying set to the lambda. *)
val fold_set_and_values : (_, 'a) t
                        -> init:'b
                        -> f:('b -> Set.t -> 'a -> 'b)
                        -> 'b

(** Fold over the indices [0,size) and values. *)
val fold_indices_and_values : (_, 'a) t
                            -> init:'b
                            -> f:('b -> int -> 'a -> 'b)
                            -> 'b

(* Map the values, the internal storage doesn't change. *)
val map : ('o, 'a) t
        -> ('b -> 'b -> bool)
        -> f:('a -> 'b)
        -> ('o, 'b) t

(* Iterate over the entries and values. *)
val iter_set : ('o, 'a) t -> f:(int -> 'a -> unit) -> unit

(* Return the values, in ascending order, in an array. *)
val to_array : (ascending, 'a) t -> 'a array

(** Diagnostic methods. These are not strictly necessary for the operations of
    the Parametric PHMM but are exposed here for interactive use. *)

(* The size of the partition. Specifically, if [size t = n] then [get t i] will
   succeed for [0, n).  *)
val size : (_, 'a) t -> int

(* The number of unique elements in the underlying assoc . *)
val length : (_, 'a) t -> int

val descending : (ascending, 'a) t -> (descending, 'a) t

(** Set a value. *)
val set : (ascending, 'a) t -> int -> 'a -> (ascending, 'a) t

val cpair : f:('a -> 'a -> 'b)
          -> ('b -> 'b -> bool)
          -> (ascending, 'a) t
          -> (ascending, 'b) t
