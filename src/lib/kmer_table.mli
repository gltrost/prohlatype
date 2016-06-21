(** Storage of K-mer keyed data.

    Each table is specific to a given K, specific at construction time.
    Using a string of different length from K will result in unspecified
    behavior.*)

(** Kmer table. *)
type 'a t

type index = int

(** The [k] used when constructing a table. *)
val k : 'a t -> int

(** [make k default] initialize a table to store [k]-mers with all values
    set to [default]. *)
val make : int -> 'a -> 'a t

(** [update f table index] mutate the value at index (as computed by
    {!Kmer_to_int.encode}) in [table] by [f].*)
val update : ( 'a -> 'a) -> 'a t -> index -> unit

(** [lookup table kmer] *)
val lookup : 'a t -> string -> 'a

(** [fold f init table] *)
val fold : f:('a -> 'b -> 'a) -> init:'a -> 'b t -> 'a

(** [iter f table] *)
val iter : f:('a -> unit) -> 'a t -> unit

(** Application specific. *)

(** For a kmer count build an array of the occurences of Kmers
    of the indexed size.*)
val distr : int t -> int array

(** Against the Spirit -- Testing only *)

(** [init k f] initialize a table to store [k]-mers by calling [f] on possible
    [k]-mers. This method is "against the spirit" of this module and should
    only be used for testing. *)
val init : int -> (string -> 'a) -> 'a t

(** [update_kmer f kmer table] will mutate the value associated with [kmer] in [table]
    by calling [f]. *)
val update_kmer : ('a -> 'a) -> string -> 'a t -> unit

