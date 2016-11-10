(* Merging of alignment element sequences.

Problem: There are many (10x) more nucleic allele sequences than genetic ones.
But the genetic sequences allow us to match many more reads. We would like to
"impute" sequences for (and hence a graph containing) all of the alleles for
which we have nucleic sequence data. To accomplish this, we use the current
nucleic sequences as scaffolding around which we append information from the
genetic ones.

The algorithm proceeds in several steps. At a high level for a given gene
(ex. HLA-A) we:

  1. Use the reference allele to construct a set of instructions for how to
     zip the exons into the introns.
  2. Afterwards we use those instructions to, merge the reference.
  3. Merge all alleles where we have both nucleic and genetic data.
  4. Finally for the other alleles we use the same instructions to merge the
     them with the closest allele for which we have genetic data.

At a lower level:

*)
open Util

let supported_genes = [ "A"; "B"; "C"]

let list_map_consecutives f lst =
  let rec loop acc = function
    | []
    | _ :: []     -> List.rev acc
    | a :: b :: t -> loop (f a b :: acc) (b :: t)
  in
  loop [] lst

type boundary_marker =
  { index     : int     (* Which segment? *)
  ; position  : int     (* Position of the boundary marker. *)
  ; length    : int     (* Length to next boundary
                        , or 1 + the total length of the following segment. *)
  }

let bm ~index ~position = { index; position; length = 0 }
let before_start_boundary = bm ~index:(-1) ~position:(-1)
let before_start bm = bm.index = -1

let to_boundary ?(offset=0) { index; position; _ } =
  Mas_parser.Boundary { idx = index; pos = position + offset }

let matches_boundary { index; position; _ } = function
  | Mas_parser.Boundary b when b.idx = index &&  b.pos = position -> true
  | _ -> false

let bm_to_string { index; position; length } =
  sprintf "{index: %d; position: %d; length %d }" index position length

let bm_to_boundary_string { index; position; _ } =
  sprintf "{idx: %d; pos: %d}" index position

let bounded lst =
  let open Mas_parser in
  let il bm i = { bm with length = bm.length + i } in
  let rec loop curb curs acc = function
    | []               -> List.rev ((il curb 1, curs) :: acc)
    | Boundary bp :: t -> let newb = bm ~index:bp.idx ~position:bp.pos in
                          loop newb                           ""            ((il curb 1, curs) :: acc)  t
    | Start s :: t     -> let newb = if before_start curb then { curb with position = s - 1 } else curb in
                          loop newb                           curs          acc                         t
    | End _ :: t       -> loop curb                           curs          acc                         t
    | Gap g :: t       -> loop (il curb g.length)             curs          acc                         t
    | Sequence s :: t  -> loop (il curb (String.length s.s))  (curs ^ s.s)  acc                         t
  in
  loop before_start_boundary "" [] lst

type 'a region =
  { bm        : boundary_marker
  ; offset    : int
  ; sequence  : 'a
  }

let region_to_string sequence_to_string { bm; offset; sequence } =
  sprintf "{ bm: %s; offset: %d; sequence: %s}"
    (bm_to_string bm) offset (sequence_to_string sequence)

type 'a instruction =
  | FillFromGenetic of 'a region
  | MergeFromNuclear of
      { nuclear : 'a region
      ; genetic : 'a region
      }

let instruction_to_string sequence_to_string = function
  | FillFromGenetic r ->
      sprintf "FillFromGenetic %s"
        (region_to_string sequence_to_string r)
  | MergeFromNuclear { nuclear; genetic; } ->
      sprintf "MergeFromNuclear { nuclear: %s; genetic: %s }"
        (region_to_string sequence_to_string nuclear)
        (region_to_string sequence_to_string genetic)

let bounded_results_to_string lst =
  String.concat ~sep:";"
    (List.map lst ~f:(fun (bm, seq) ->
      sprintf "(%s, %s)" (bm_to_string bm) (short_seq seq)))

(* Create a framework of instructions based off of, probably the alignment
   in the reference sequence. *)
let zip_align ~gen ~nuc =
  let rec loop next_bnd_pos acc g n =
    match n with
    | []        ->
        let _p, rest =
          List.fold_left g ~init:(next_bnd_pos, acc)
            ~f:(fun (next_bnd_pos, acc) (genetic, sequence) ->
                  let offset = next_bnd_pos - genetic.position in
                  let next_end_pos = genetic.position + genetic.length in
                  let instr = FillFromGenetic { bm = genetic; sequence; offset } in
                  (next_end_pos, instr :: acc))
        in
        Ok (List.rev rest)
    | (nuclear, nuc_sequence) :: nt  ->
        begin
          match g with
          | []       -> error "Reached end of genetic sequence before nuclear: %s"
                          (bounded_results_to_string n)
          | (genetic, sequence) :: gt ->
              if sequence = nuc_sequence then
                let genetic  =
                  { bm       = genetic
                  ; offset   = next_bnd_pos - genetic.position
                  ; sequence = sequence
                  }
                in
                let nuclear  =
                  { bm       = nuclear
                  ; offset   = next_bnd_pos (*+ genetic.position*) - nuclear.position
                  ; sequence = nuc_sequence
                  }
                in
                let instr = MergeFromNuclear { genetic ; nuclear } in
                loop (next_bnd_pos + nuclear.bm.length) (instr :: acc) gt nt
              else
                let instr = FillFromGenetic
                  { bm = genetic
                  ; sequence
                  ; offset = next_bnd_pos - genetic.position
                  }
                in
                loop (next_bnd_pos + genetic.length) (instr :: acc) gt n
        end
  in
  match gen with
  | []           -> error "Empty genetic sequence!"
  | (bm, _) :: _ -> let next_bnd_pos = bm.position in
                    loop next_bnd_pos [] gen nuc

let prefix_from_f s =
  match String.split s ~on:(`Character '_') with
  | [p; _] -> p
  | _      -> invalid_argf "Missing '_' in %s" s

let align_from_prefix prefix_path =
  let gen_mp = Mas_parser.from_file (prefix_path ^ "_gen.txt") in
  let nuc_mp = Mas_parser.from_file (prefix_path ^ "_nuc.txt") in
  let gen = bounded gen_mp.Mas_parser.ref_elems in
  let nuc = bounded nuc_mp.Mas_parser.ref_elems in
  zip_align ~gen ~nuc >>= fun i -> Ok (gen_mp, nuc_mp, i)

type state =
  { seen_start  : bool
  ; seen_end    : bool
  ; seen_nuclear_start : bool
  ; seen_nuclear_end   : bool
  ; acc         : string Mas_parser.alignment_element list
  }

let start_state =
  { seen_start  = false
  ; seen_end    = false
  ; seen_nuclear_start = false
  ; seen_nuclear_end   = false
  ; acc         = []
  }

let position =
  let open Mas_parser in function
    | Start s     -> s
    | End e       -> e
    | Gap g       -> g.start
    | Sequence s  -> s.start
    | Boundary b  -> b.pos


let latest_position =
  let open Mas_parser in function
    | Start s     -> s
    | End e       -> e
    | Gap g       -> (g.start + g.length)
    | Sequence s  -> (s.start + String.length s.s)
    | Boundary b  -> b.pos

let latest_position_al_elems = function
  | []     -> error "No latest alignment element."
  | h :: _ -> Ok (latest_position h)

let sequence_start_check ~bm st lst k =
  match bm with
  | `Nothing                                -> k st lst
  | `DontCheckBut kb                        -> k (kb st) lst
  | `CheckAnd (sbm, kb) ->
      match lst with
      | b :: t when matches_boundary sbm b  -> k (kb b st) t
      | []      -> error "Did not start with Boundary %s but empty."
                        (bm_to_boundary_string sbm)
      | v :: _t -> error "Did not start with Boundary %s but with %s."
                        (bm_to_boundary_string sbm)
                        (Mas_parser.al_el_to_string v)

let list_remove_first p lst =
  let rec loop acc = function
    | []     -> List.rev acc
    | h :: t -> if p h then List.rev acc @ t else loop (h :: acc) t
  in
  loop [] lst

let is_end = function | Mas_parser.End _ -> true | _ -> false
let is_start = function | Mas_parser.Start _ -> true | _ -> false

let map_al_el offset =
  let open Mas_parser in function
  | Boundary b -> Boundary { b with pos = b.pos + offset}
  | Start s    -> Start (s + offset)
  | End e      -> End (e + offset)
  | Gap g      -> Gap { g with start = g.start + offset }
  | Sequence s -> Sequence { s with start = s.start + offset}

let update offset s =
  let open Mas_parser in function
  | Boundary b -> { s with acc = Boundary { b with pos = b.pos + offset} :: s.acc }
  | Start t    -> if s.seen_start then s else
                    { s with acc = Start (t + offset) :: s.acc
                           ; seen_start = true}
  | End e      -> let without_end = if s.seen_end then list_remove_first is_end s.acc else s.acc in
                  { s with acc = End (e + offset) :: without_end
                         ; seen_end = true }
  | Gap g      -> { s with acc = Gap { g with start = g.start + offset } :: s.acc }
  | Sequence t -> if s.seen_start && s.seen_end then  (* Not quiet right, TODO! *)
                    let without_end = list_remove_first is_end s.acc in
                    { s with seen_end = false
                           ; acc = Sequence { t with start = t.start + offset}
                                  :: without_end }
                  else
                    { s with acc = Sequence { t with start = t.start + offset} :: s.acc }

let set_seen_nuclear_start s =
  { s with seen_nuclear_start = true }

let set_seen_nuclear_end s =
  { s with seen_nuclear_end = true }

let accumulate_up_to_next_boundary_rev ~bm offset nuclear s lst =
  let open Mas_parser in
  let rec loop s = function
    | []
    | (Boundary _ :: _) as l            -> Ok (s, l)
  (*| (Start _ as e) :: tl when nuclear -> loop (update offset (set_seen_nuclear_start s) e) tl
    | (End _ as e) :: tl when nuclear   -> loop (update offset (set_seen_nuclear_end s) e) tl *)
    | (Start _ as e) :: tl
    | (End _ as e) :: tl
    | (Sequence _ as e) :: tl
    | (Gap _ as e) :: tl                -> loop (update offset s e) tl
  in
  sequence_start_check ~bm s lst loop

let drop_until_boundary ~bm lst =
  let open Mas_parser in
  let rec loop () = function
    | []                      -> Ok []
    | (Start _) :: t
    | (End _ ) :: t
    | (Sequence _) :: t
    | (Gap _) :: t            -> loop () t
    | (Boundary _ :: t) as l  -> Ok l
  in
  sequence_start_check ~bm () lst loop

let alignment_elements_to_string lst =
  String.concat ~sep:";\n" (List.map ~f:Mas_parser.al_el_to_string lst)

let not_boundary_with_pos pos = function
  | Mas_parser.Boundary b when b.pos = pos -> false
  | _ -> true

let list_split_and_map lst ~p ~f =
  let rec loop acc = function
    | h :: t when p h -> loop (f h :: acc) t
    | lst             -> (List.rev acc, lst)
  in
  loop [] lst

let split_at_boundary_and_offset ~offset ~pos =
  list_split_and_map ~p:(not_boundary_with_pos pos) ~f:(map_al_el offset)

let split_at_end =
  list_split_and_map ~p:(is_end) ~f:id

let split_at_start =
  list_split_and_map ~p:(is_start) ~f:id

(* Droping the boundary from the returned result simplifies the special casing.
   We now know that we (might) have to add (not for the first one!) the
   boundaries from the instructions. *)
let split_at_boundary_offset_before_and_drop_it ~offset ~pos lst =
  match split_at_boundary_and_offset ~offset ~pos lst with
  | before, (_bnd :: after) -> before, after
  | before, []              -> before, []

let replace_sequence r s = { r with sequence = s }

let map_instr_to_alignments ?(fail_on_empty=true) ~gen ~nuc alg =
  let rec start = function
    | FillFromGenetic f :: tl when before_start f.bm ->
                fill_from_g [] f tl ~gen ~nuc
    | []     -> error "Empty instructions"
    | s :: _ -> error "Did not start with a \"starting\" FillFromGenetic but %s"
                  (instruction_to_string id s)
  and loop acc ~gen ~nuc = function
    | MergeFromNuclear {genetic; nuclear} :: tl -> merge_from_n acc genetic nuclear tl ~gen ~nuc
    | FillFromGenetic f :: tl                   -> fill_from_g acc f tl ~gen ~nuc
    | []  ->
        if fail_on_empty && gen <> [] then
          error "After all instructions genetic not empty: %s."
            (alignment_elements_to_string gen)
        else if fail_on_empty && nuc <> [] then
          error "After all instructions nuclear sequence not empty: %s."
            (alignment_elements_to_string nuc)
        else
          Ok (List.rev acc)
  and fill_from_g acc f tl ~gen ~nuc =
    let pos     = f.bm.position + f.bm.length in
    let before, after = split_at_boundary_offset_before_and_drop_it ~pos ~offset:f.offset gen in
    let nacc = FillFromGenetic (replace_sequence f before) :: acc in
    loop nacc ~gen:after ~nuc tl
 and merge_from_n acc genetic nuclear tl ~gen ~nuc =
    let gen_pos = genetic.bm.position + genetic.bm.length in
    let gen_els, gen_after = split_at_boundary_offset_before_and_drop_it
      ~pos:gen_pos ~offset:genetic.offset gen
    in
    let nuc_pos = nuclear.bm.position + nuclear.bm.length in
    let nuc_els, nuc_after = split_at_boundary_offset_before_and_drop_it
      ~pos:nuc_pos ~offset:nuclear.offset nuc
    in
    let nacc = MergeFromNuclear
      { genetic = replace_sequence genetic gen_els
      ; nuclear = replace_sequence nuclear nuc_els
      } :: acc
    in
    loop nacc ~gen:gen_after ~nuc:nuc_after tl
  in
  start alg

let without_starts_or_ends =
  let open Mas_parser in
  List.filter ~f:(function
    | Start _
    | End _       -> false
    | Boundary _
    | Gap _
    | Sequence _  -> true)

let align_reference instr =
  List.map instr ~f:(function
    | FillFromGenetic f ->
        if before_start f.bm then
          f.sequence
        else
          to_boundary ~offset:f.offset f.bm :: f.sequence
    | MergeFromNuclear { genetic; nuclear } ->
        to_boundary ~offset:genetic.offset genetic.bm ::
          (* This will work fine for A,B,C but not for DRB where there are
             restarts in the reference! *)
          without_starts_or_ends nuclear.sequence)
  |> List.concat

let align_same name instr =
  let open Mas_parser in
  let only_gaps = List.for_all ~f:(function | Gap _ -> true | _ -> false) in
  let check_for_ends start nuclear_sequence next_boundary_pos acc =
    match split_at_end nuclear_sequence with
    | before, []         -> (start before) :: acc, true, false
    | before, e :: after ->
        if position e = next_boundary_pos then
          if after <> [] then
            invalid_argf "In %s malformed nuclear sequence: %s after end but before next boundary."
              name (alignment_elements_to_string after)
          else
            (start before) :: acc, false, false
        else if only_gaps after then
          (start nuclear_sequence) :: acc, false, true  (* Keep the gap to signal missing *)
        else
          invalid_argf "In %s Did not find just gaps after end: %s"
            name (alignment_elements_to_string after)
  in
  let latest_position_or_invalid = function
    | []      -> invalid_argf "In %s empty acc, merging right away?" name
    | [] :: _ -> invalid_argf "In %s empty element on acc" name
    | ls :: _ -> List.last ls
                 |> Option.value_exn ~msg:"We checked for non empty list!"
                 |> latest_position
  in
  let init =
    []      (* acummulator of (list of) alignment elements list.  *)
    , false (* are inside the nucleic acid sequence, we have data for it! *)
    , false (* need to add a start. *)
  in
  List.fold_left instr ~init ~f:(fun (acc, have_n_seq, need_start) instr ->
    match instr with
    | FillFromGenetic f ->
        if before_start f.bm then
          f.sequence :: acc, have_n_seq, false
        else
          let sbm = to_boundary f.bm in
          if need_start then
            (Start f.bm.position :: sbm :: f.sequence) :: acc, have_n_seq, false
          else
            (sbm :: f.sequence) :: acc, have_n_seq, false
    | MergeFromNuclear { genetic; nuclear } ->
        let next_boundary_pos = nuclear.bm.position + nuclear.bm.length in
        let start_boundary = to_boundary genetic.bm in
        if have_n_seq then  (* Within nuclear data *)
          check_for_ends (fun l -> start_boundary :: l) nuclear.sequence next_boundary_pos acc
        else
          begin match split_at_start nuclear.sequence with
          | before, [] ->
              (* Did NOT find a start when we haven't started we have missing data! *)
              if not (only_gaps before) then
                invalid_argf "In %s did not find just gaps before start: %s"
                  name (alignment_elements_to_string before)
              else
                let lp = latest_position_or_invalid acc in
                [End lp] :: acc, false, true
          | before, s :: after ->
              if not (only_gaps before) then
                invalid_argf "In %s did not find just gaps before start: %s"
                  name (alignment_elements_to_string before)
              else
                if position s = nuclear.bm.position + 1 then
                  check_for_ends (fun l -> start_boundary :: l) after next_boundary_pos acc
                else
                  let lp = latest_position_or_invalid acc in
                  check_for_ends (fun l -> End lp :: s :: start_boundary :: l)
                    after next_boundary_pos acc
          end)


(* Nuc goes into gen!
  - What about if the underlying merging sequences do not have the sequences
    across the boundaries assumed by the instructions generated against the
    reference?
let apply_align_instr ?(fail_on_empty=true) ~gen ~nuc alg =
  let rec start gen nuc = function
    (* Assume that the instructions start with a fill command from genetic sequences *)
    | FillFromGenetic f :: tl when before_start f.bm ->
        (*first_position_al_elems gen >>= fun start_pos -> *)
          accumulate_up_to_next_boundary_rev f.offset false start_state gen ~bm:`Nothing >>=
            fun (state, gen) -> loop state ~gen ~nuc tl
    | []     -> error "Empty instructions"
    | s :: _ -> error "Did not start with a starting FillFromGenetic but %s"
                  (instruction_to_string s)
  and loop state ~gen ~nuc = function
    | MergeFromNuclear m :: tl ->
        if not state.seen_nuclear_start then      (* before *)
          failwith "NI"
          (*
          if before_start m.nuclear then
            `DontCheckBut (fun s -> update m.genetic_offset s genetic_boundary)
          else
            *)


        else if not state.seen_nuclear_end then   (* middle  *)
          (* Just add elements from nuclear sequence. *)
          let genetic_boundary = to_boundary m.genetic in
          let bm =
             `CheckAnd( m.nuclear
                      , fun _b s -> update m.genetic_offset s genetic_boundary)
          in
          accumulate_up_to_next_boundary_rev m.nuclear_offset true state nuc ~bm >>=
            begin fun (nstate, ntl) ->
              (* Modulo new gaps due to different sequences, and if gen and nuc
                come from the same allele, these should be the same.
                Instead of dropping we should check that they are! *)
              drop_until_boundary ~bm:(`CheckAnd (m.genetic, (fun _ a -> a))) gen >>=
                fun gen -> loop nstate ~gen ~nuc:ntl tl
            end


        else if state.seen_nuclear_end   then (* after  *)

          accumulate_up_to_next_boundary_rev m.nuclear_offset false state gen
            ~bm:(`CheckAnd (m.genetic, (fun b s -> update m.nuclear_offset s b))) >>=
              fun (nstate, gen) -> loop nstate ~gen ~nuc tl
        else
          assert false
        (*let () =
          match nuc with
          |
          Printf.printf "Merging from nuclear: %s %s\n"
        (List.hd_exn nuc |> Mas_parser.al_el_to_string)
        (List.tl_exn nuc |> List.hd_exn |> Mas_parser.al_el_to_string)
          in *)
    | FillFromGenetic f :: tl ->
        accumulate_up_to_next_boundary_rev f.offset false state gen
          ~bm:(`CheckAnd (f.genetic, (fun b s -> update f.offset s b))) >>=
          fun (nstate, gen) -> loop nstate ~gen ~nuc tl
    | [] ->
        if fail_on_empty && gen <> [] then
          error "After all instructions genetic not empty: %s."
            (alignment_elements_to_string gen)
        else if fail_on_empty && nuc <> [] then
          error "After all instructions nuclear sequence not empty: %s."
            (alignment_elements_to_string nuc)
        else if state.seen_end then
            Ok (List.rev state.acc)
        else
          latest_position_al_elems state.acc >>= fun p ->
            Ok (List.rev (Mas_parser.End p :: state.acc))
  in
  start gen nuc alg
*)

let reference_positions_align ?seq lst =
  let open Mas_parser in
  let emst = Option.value (Option.map seq ~f:(sprintf "For seq %s ")) ~default:"" in
  let nerror n p = error "%spositions are not aligned: %s, pos: %d" emst (al_el_to_string n) p in
  let rec loop p = function
    | []                      -> Ok p
    | (Boundary b as v) :: t  -> if b.pos = p then loop (p + 1) t else nerror v p
    | (Start s as v) :: t     -> if s = p then loop p t else nerror v p
    | (End e as v) :: t       -> if e = p then loop p t else nerror v p
    | (Gap g as v) :: t       -> if g.start = p then loop (p + g.length) t else nerror v p
    | (Sequence s as v) :: t  -> if s.start = p then loop (p + (String.length s.s)) t else nerror v p
  and start = function
    | (Boundary b) :: t  -> loop b.pos t
    | (Start s) :: t     -> loop s t
    | (Gap g) :: t       -> loop g.start t
    | x :: _             -> error "Can't start with %s." (al_el_to_string x)
    | []                 -> error "Empty"
  in
  start lst

let init_trie elems =
  let open Nomenclature in
  list_fold_ok elems ~init:Trie.empty ~f:(fun trie s ->
    parse s >>= fun (_gene, (allele_resolution, suffix_opt)) ->
      Ok (Trie.add allele_resolution suffix_opt trie))

module RMap = Map.Make (struct
    type t = Nomenclature.resolution * Nomenclature.suffix option
    let compare = compare
    end)

let init_trie_and_map elems =
  let open Nomenclature in
  list_fold_ok elems ~init:(Trie.empty, RMap.empty)
    ~f:(fun (trie, mp) (s, seq) ->
        parse s >>= fun (_gene, (allele_resolution, suffix_opt)) ->
          Ok ( Trie.add allele_resolution suffix_opt trie
             , RMap.add (allele_resolution, suffix_opt) seq mp))

(* TODO: Figure out a way around this special case. Maybe when we do our
   own alignment? *)
let c0409N_exon_extension =
  "GACAGCTGCCTGTGTGGGACTGAGATGCAGGATTTCTTCACACCTCTCCTTTGTGACTTCAAGAGCCTCTGGCATCTCTTTCTGCAAAGGCATCTGA"
(*
let new_alts ?(assume_genetic_has_correct_exons=false) ~nuc instr trie rmp =
  let open Nomenclature in
  list_fold_ok nuc ~init:([], []) ~f:(fun (alt_acc, map_acc) (alt_name, nuc) ->
    (* Check that the gene is always the same? *)
    parse alt_name >>= fun (gene, ((allele_resolution, _so) as np)) ->
      let closest_allele_res = Trie.nearest allele_resolution trie in
      if assume_genetic_has_correct_exons && closest_allele_res = np then
        Ok ((alt_name, nuc) :: alt_acc
           ,(alt_name, alt_name) :: map_acc)
      else
        let gen = RMap.find closest_allele_res rmp in
        let closest_allele_str = resolution_and_suffix_opt_to_string ~gene closest_allele_res in
        (*Printf.printf "%s (nuc) -> %s (gen)" alt_name closest_allele_str; *)
        let nuc = if alt_name <> "C*04:09N" then nuc else
          List.filter nuc ~f:(function
            | Mas_parser.Sequence { s; _ } when s = c0409N_exon_extension -> false
            | _ -> true)
        in
        apply_align_instr ~gen ~nuc instr >>= fun new_alts ->
          Ok ((alt_name, new_alts) :: alt_acc
            , (alt_name, closest_allele_str) :: map_acc))
            *)

(* TODO. We need to make a decision about suffixed (ex. with 'N') alleles
   since they may be the closest. *)


let and_check prefix =
  let open Mas_parser in
  align_from_prefix prefix >>= fun (gen_mp, nuc_mp, instr) ->
    if gen_mp.reference <> nuc_mp.reference then
      error "References don't match %s vs %s" gen_mp.reference nuc_mp.reference
    else if gen_mp.align_date <> nuc_mp.align_date then
      error "Align dates don't match %s vs %s" gen_mp.align_date nuc_mp.align_date
    else
      map_instr_to_alignments ~gen:gen_mp.ref_elems ~nuc:nuc_mp.ref_elems instr >>= fun ref_instr ->
        let new_ref_elems = align_reference ref_instr in
      (*apply_align_instr ~gen:gen_mp.ref_elems ~nuc:nuc_mp.ref_elems instr >>= fun new_ref_elems -> *)
        reference_positions_align ~seq:("reference:" ^ gen_mp.reference) new_ref_elems >>= fun _ref_position_check ->
          (*
          let seq_assoc = (gen_mp.reference, gen_mp.ref_elems) :: gen_mp.alt_elems in
          init_trie_and_map seq_assoc >>= fun (gtrie, rmap) ->
            new_alts nuc_mp.alt_elems instr gtrie rmap >>= fun (alt_lst, map_lst) ->
              *)
              Ok ({ align_date = gen_mp.align_date
                  ; reference  = gen_mp.reference
                  ; ref_elems  = new_ref_elems
                  ; alt_elems  = [] (* alt_lst *)
                  } ,
                  [] (*map_lst*))
