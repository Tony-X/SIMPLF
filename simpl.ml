open Simpltypes;;

type vartyp =
        Undeclared
      | VTyp of (ityp * bool)

type typctx = varname -> vartyp

type cmdtyp = TypCtx of typctx | CTypErr of string

type exprtyp = ExpTyp of ityp | ETypErr of string

let update s v i = (fun x -> if x=v then i else (s x));;

let init_typctx (l : (varname*vartyp) list) : typctx =
  fun x -> (try (List.assoc x l) with Not_found -> Undeclared);;

let li2str ((l1,c1),(l2,c2)) = 
	"In "^(string_of_int l1)^":"^(string_of_int c1)^"-"^
		  (string_of_int l2)^":"^(string_of_int c2)^": ";;

let eerr li s = ETypErr( (li2str li)^s);;
let cerr li s = CTypErr( (li2str li)^s);;
  
let rec typchk_expr (tc:typctx) (e:iexpr) : exprtyp =
  let typchk_op name argtyp rettyp (e1,e2,li) : exprtyp = 
	( match ( typchk_expr tc e1, typchk_expr tc e2) with
	    ( ETypErr s, _) | ( _,ETypErr s)  -> ETypErr s
		|(ExpTyp t1, ExpTyp t2) ->
			if ( t1 = argtyp && t2=argtyp ) then (ExpTyp rettyp)
			else eerr li ("type-mismatch in argument to "^name)) in
	
	( match e with 
	  Const _ -> ExpTyp TypInt
	| Var(v,li) -> (match ( tc v) with
				      VTyp (t,true) -> ExpTyp t
					| VTyp (_,false) -> eerr li ("variable "^v^" used uninitialized")
					| Undeclared -> eerr li ("variable "^v^" used undeclared"))
	| Plus x -> typchk_op "+" TypInt TypInt x
	| Minus x -> typchk_op "-" TypInt TypInt x
	| Times x -> typchk_op "*" TypInt TypInt x
	| True _ | False _ -> ExpTyp TypBool
	| Leq x -> typchk_op "<=" TypInt TypBool x
	| Conj x -> typchk_op "&&" TypBool TypBool x
	| Disj x -> typchk_op "||" TypBool TypBool x
	| Neg (e1,li) -> typchk_op "!" TypBool TypBool (e1,True li, li)
	| Abstraction ( al, c, li) -> ( let g acc x = ( update acc (fst x) (snd x)) in
										let tc1 = List.fold_left g tc (List.map (fun (nm,typ,_) -> (nm,VTyp(typ,true))) al) in
											match ( typchk_cmd tc1 c) with
											  CTypErr s -> ETypErr s
											| TypCtx tc2 -> ( match ( tc2 "ret" ) with
															  Undeclared -> eerr li ("ret undefined")
															| VTyp (t,p) -> if p=true then ExpTyp ( TypFunc( (List.map (fun (_,x,_)-> x) al),t) ) 
																					  else eerr li ("ret uninitialized within fucntion") ))
	| Apply ( e1, el, li) -> (  match ( typchk_expr tc e1) with
								  ETypErr s -> ETypErr s
								| ExpTyp t0 -> ( match t0 with
												  TypInt | TypBool -> eerr li "can't apply non-abstraction "
												| TypFunc (tl,rettyp) ->  ( let lformal = List.length tl in 
																			  let larg = List.length el in
																				if lformal <> larg then (eerr li ("requies "^(string_of_int lformal)^" arguments, not "^(string_of_int larg)))
																								   else 
																								   (
																									  let f (e,t) = ( match ( typchk_expr tc e) with
																													   ExpTyp typ -> (if typ=t then true
																																	  else false)
																													 | _ -> false) in
																										let l = List.length (List.filter f (List.combine el tl)) in
																											if l=larg then ExpTyp rettyp
																													  else eerr li "argument type-mismatch(es)"
																								   )
																								   
																			)
												)
							  )
			)							

and typchk_cmd (tc:typctx) (c:icmd) : cmdtyp =
  (match c with 
      Skip _ -> TypCtx tc
	| Seq (c1,c2,_) -> ( match (typchk_cmd tc c1) with 
	                        CTypErr s -> CTypErr s
						  | TypCtx tc2 -> (typchk_cmd tc2 c2))
	| Assign (v,e1,li) -> 
		( match (tc v, typchk_expr tc e1) with
	        ( _, ETypErr s ) -> CTypErr s
		  | (VTyp (t1,_), ExpTyp t2) -> if t1=t2 then TypCtx( update tc v (VTyp(t1,true)))
									    else cerr li ("type-mismatch in assignment to " ^ v)
		  | (Undeclared,_) -> cerr li ("assignment to undeclared var " ^ v))
	| Cond (e1,c1,c2,li) -> 
	  ( match (typchk_expr tc e1, typchk_cmd tc c1, typchk_cmd tc c2) with
	      (ETypErr s,_,_) | ( _, CTypErr s, _) | ( _, _, CTypErr s) -> CTypErr s
		| (ExpTyp TypBool, TypCtx _, TypCtx _) -> TypCtx tc
		| (ExpTyp _, TypCtx _, TypCtx _) -> cerr li "if test is not a bool")
	| While ( e1,c1,li) -> 
	  ( match ( typchk_expr tc e1, typchk_cmd tc c1) with 
	      ( ETypErr s, _ ) | ( ExpTyp _, CTypErr s) -> CTypErr s
		| ( ExpTyp TypBool, TypCtx _) -> TypCtx tc
		| ( ExpTyp _, TypCtx _) -> cerr li "while test is not a bool")
	| Decl ( t, v,li) -> ( match ( tc v) with 
							Undeclared -> TypCtx ( update tc v (VTyp(t,false)))
						  | _ -> cerr li ("name conflict with: "^v)));;
		 
(* The interpreter may throw the SegFault exception if it ever encounters
 * a stuck state. *)
exception SegFault

(* Stores now map variable names to either integers or code. Code consists
 * of a command and a list of the names of the variables it takes as input. *)
type heapval = Data of int | Code of (varname list * icmd)
type store = varname -> heapval

let init_store (l : (varname*heapval) list) : store =
  fun x -> List.assoc x l;;

let rec eval_expr (s:store) (e:iexpr) : heapval =

  let eval_intop f (e1,e2,_) =
    (match (eval_expr s e1, eval_expr s e2) with
       (Data n1, Data n2) -> Data (f n1 n2)
     | _ -> raise SegFault) in

  let eval_boolop f =
    eval_intop (fun x y -> if (f (x<>0) (y<>0)) then 1 else 0) in

  (match e with
     Const (n,_) -> Data n
   | Var (x,_) -> (s x)
   | Plus z -> eval_intop (+) z
   | Minus z -> eval_intop (-) z
   | Times z -> eval_intop ( * ) z
   | True _ -> Data 1
   | False _ -> Data 0
   | Leq z -> eval_intop (fun x y -> if x<=y then 1 else 0) z
   | Conj z -> eval_boolop (&&) z
   | Disj z -> eval_boolop (||) z
   | Neg (e1,li) -> eval_boolop (fun x _ -> not x) (e1,True li,li)
   | Abstraction (al,c,_) -> Code( List.map (fun (x,_,_)-> x) al, c)
   | Apply (e1,el,_) -> ( let v = eval_expr s e1 in 
							( match v with
							    Data _ -> raise SegFault 
							  | Code ( vl, c) -> ( let ulist = List.map (eval_expr s) el in 
													  let s2 = List.fold_left (fun acc e -> update acc (fst e) (snd e) ) s (List.combine vl ulist) in
													    let s3 = exec_cmd s2 c in
															s3 "ret"
												  )
							)
						)
	)

and exec_cmd (s:store) (c:icmd) : store =
  (match c with
     Skip _ | Decl _ -> s
   | Seq (c1,c2,_) -> exec_cmd (exec_cmd s c1) c2
   | Assign (v,e,_) -> update s v (eval_expr s e)
   | Cond (e,c1,c2,_) ->
       exec_cmd s (if (eval_expr s e)=(Data 0) then c2 else c1)
   | While (e,c1,li) -> exec_cmd s (Cond (e,Seq (c1,c,li),Skip li,li))
  );;



let main () =
   let argval = (function "true" -> 1 | "false" -> 0 | x -> int_of_string x) in
   let argtyp = (function "true" | "false" -> TypBool | _ -> TypInt) in
   let c = (Simplparser.parse_cmd Simpllexer.token 
              (Lexing.from_channel (open_in Sys.argv.(1)))) in
   let s = init_store (List.tl (List.tl (Array.to_list (Array.mapi
             (fun i a -> ("arg"^(string_of_int (i-2)),
                          Data (if i>=2 then (argval a) else 0)))
               Sys.argv)))) in
   let tc = init_typctx (List.tl (List.tl (Array.to_list (Array.mapi
             (fun i a -> ("arg"^(string_of_int (i-2)), VTyp (argtyp a,true)))
             Sys.argv)))) in
   (match (typchk_cmd tc c) with
      CTypErr s -> print_string ("Typing error: "^s^"\n")
    | TypCtx tc' -> (print_string
        (match (tc' "ret") with
           Undeclared -> "Typing error: return value undeclared"
         | VTyp(_,false) -> "Typing error: return value uninitialized"
         | VTyp(rtyp,true) ->
             (match (exec_cmd s c "ret") with
                Code _ -> "<code>"
              | Data n -> if rtyp=TypInt then (string_of_int n)
                          else if n=0 then "false" else "true"));
        print_newline ()));;

main ();;

