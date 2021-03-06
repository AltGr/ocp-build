(******************************************************************************)
(*                                                                            *)
(*                          TypeRex OCaml Tools                               *)
(*                                                                            *)
(*                               OCamlPro                                     *)
(*                                                                            *)
(*    Copyright 2011-2012 OCamlPro                                            *)
(*    All rights reserved.  See accompanying files for the terms under        *)
(*    which this file is distributed. In doubt, contact us at                 *)
(*    contact@ocamlpro.com (http://www.ocamlpro.com/)                         *)
(*                                                                            *)
(******************************************************************************)

(* TODO: we should save the version of ocaml used to build a project,
   so that we can detect changes and ask for a clean before building.
   Can we access the magic used by every compiler ? (we can compile an
   empty file in bytecode and native code) We could cache this
   information using the uniq identifier of the executable (would not
   work with wrappers).
*)

(* TODO
   We could force packages with missing dependencies to still be compiaboutled,
   since it is still possible that these missing dependencies arbue not used
   in a particular compilation scheme.
*)


(* open BuildBase *)
(* open Stdlib2  *)
open SimpleConfig

open BuildOCamlConfig.TYPES
open BuildEngineTypes
open BuildOCPTypes
open BuildOCPTree
open BuildTypes
open BuildGlobals
open BuildOptions
open BuildArgs
open BuildTerm
open BuildActions

let _ = DebugVerbosity.add_submodules "B" [ "BuildMain" ]

let print_installed install_where =
  let open BuildOCamlInstall in
  Printf.printf "Installed packages:\n";
  List.iter (fun un ->
    Printf.printf "\t%s . %s (%s)\n%!"
      un.un_name un.un_version un.un_type;
    Printf.printf "\t\tin %s\n%!" un.un_directory;
  ) (BuildOCamlInstall.list_installed install_where);
  ()

let move_to_project = ref true

let finally_do = ref []
let add_finally action =
  finally_do := action :: !finally_do


let do_load_project_files cin project_dir state =
  let open ProjectOptions in

  let force_scan = ref cin.cin_autoscan in

  (* if we didn't find any .ocp files before, we should retry ! *)
  if !!root_files = [] then force_scan := true;

  if ! add_external_projects_arg <> [] then begin
    List.iter (fun dir ->
      if not (List.mem dir !!project_external_dirs_option) then begin
        must_save_project ();
        project_external_dirs_option =:= !!project_external_dirs_option @
            [ dir ];
        force_scan := true;
      end
    ) (List.rev !add_external_projects_arg)
  end;

  if !!project_ocpbuild_version != BuildVersion.version then begin
    must_save_project ();
    project_ocpbuild_version =:= BuildVersion.version;
  end;

  let nerrors =
    if !oasis_arg then
      BuildOasis.load_project state "_oasis"
    else
      begin
      if !force_scan then begin
        save_project := true;
        time_step "Scanning project for .ocp files ...";
        root_files =:= [];
        List.iter (fun dir ->
          let files = BuildOCP.scan_root dir in
          root_files =:= !!root_files @ files
        ) (project_dir ::
            (List.map File.of_string !!project_external_dirs_option));
        time_step "   Done scanning project for .ocp files";
      end;

      if !!root_files = [] then begin
        Printf.eprintf "Error: no known .ocp files\n";
        Printf.eprintf "\tHave you run ocp-build with -scan to find them ?\n%!";
        exit 2
      end;

      time_step "Loading project .ocp files...";
      let nerrors =
        let config = BuildOCP.empty_config () in
        BuildOCP.load_ocp_files config state !!root_files
      in
      time_step "   Done loading project .ocp files";
      nerrors
      end
  in
  if nerrors > 0 then exit 2


let do_print_project_info pj =

  BuildOCP.print_conflicts !print_conflicts_arg;
  let string_of_package pj =
    Printf.sprintf "   %s (%s,%s)\n     in %s\n"
      pj.package_name
      (BuildOCPTree.string_of_package_type pj.package_type)
      pj.package_source_kind
      pj.package_dirname
  in
  let print_package pj =
    Printf.eprintf "%s%!" (string_of_package pj)
  in
  if verbose 5 || !list_projects_arg then begin

    let print_package_array array =
      let list = ref [] in
      Array.iter (fun pj ->
        list := string_of_package pj :: !list) array;
      List.iter (fun s ->
        Printf.printf "%s%!" s)
        (List.sort compare !list)
    in

    Printf.eprintf "Validated packages:\n";
    print_package_array pj.project_sorted;

    Printf.eprintf "Disabled packages:\n";
    print_package_array pj.project_disabled;

  end;

  begin
    let incomplete_packages = Hashtbl.create  13 in
    if pj.project_incomplete <> [||] then begin
      Printf.eprintf "Warning: %d incomplete packages (will not be built):\n"
        (Array.length pj.project_incomplete);
      let meta_need = ref 0 in
      Array.iter (fun pk ->
        Hashtbl.add incomplete_packages pk.package_name pk;
        if !meta_verbose_arg ||
           pk.package_source_kind <> "meta" then (* TODO ? *)
          print_package pk
        else
          incr meta_need
      )
        pj.project_incomplete;
      if !meta_need > 0 then
        Printf.eprintf
          "  Hidden: %d incomplete packages in META files (use -print-incomplete-meta).\n%!" !meta_need
    end;

    if pj.project_missing <> [] then
      let absent_packages = ref [] in
      let other_packages = ref [] in
      List.iter (fun (name, list) ->
        let non_meta_need = ref false in
        if !meta_verbose_arg then
          non_meta_need := true
        else
          List.iter (fun pk ->
            if pk.package_source_kind <> "meta" then non_meta_need := true
          ) list;
        if !non_meta_need then begin
          let packages =
            if Hashtbl.mem incomplete_packages name then
              other_packages else absent_packages in
          packages := (name, list) :: !packages
        end;
      ) pj.project_missing;
      if !absent_packages <> [] then begin
        Printf.eprintf "Warning: %d needed packages are missing !\n%!"
          (List.length !absent_packages);
        List.iter (fun (name, list) ->
          Printf.eprintf "   ABSENT package %S missed by %d packages\n"
            name (List.length list);
          List.iter print_package list;
        ) !absent_packages
      end;
      List.iter (fun (name, list) ->
        Printf.eprintf "   Incomplete package %S missed by %d packages\n"
          name
          (List.length list);
        List.iter print_package list;
      ) !other_packages

  end

let do_print_fancy_project_info pj =
  let cantbuild = [] in
  let missing =
    List.filter
      (fun (_name,pkgs) ->
        List.exists (fun pk -> pk.package_source_kind <> "meta") pkgs)
      pj.project_missing
  in
  let missing_roots =
    (* remove all missing pkgs that depend on another to get the missing roots *)
    List.filter
      (fun (name,pkgs) ->
        not
          (List.exists
             (fun (_,pks) -> List.exists (fun pk -> name = pk.package_name) pks)
             missing))
      missing
  in
  let cantbuild =
    if missing = [] then cantbuild
    else if missing_roots = [] then begin (* no roots ! *)
      let rec find_cycle acc = function
        | [] -> None
        | name :: _ when List.mem name acc -> Some acc
        | name :: r ->
          let provides =
            List.map (fun pk -> pk.package_name)
              (try List.assoc name missing with Not_found -> [])
          in
          match find_cycle (name::acc) provides with
          | Some _ as r -> r
          | None -> find_cycle acc r
      in
      let cycle = List.map fst missing in
      let cycle =
        match find_cycle [] cycle with
        | Some l -> l
        | None -> assert false
      in
(*TODO: these are only errors if the corresponding packages have
 been specified as targets. *)
      Printf.eprintf
        "%sERROR%s: circular dependency between:\n"
        term.esc_red_text term.esc_end;
      List.iter
        (fun (n1,n2) -> Printf.eprintf "  - %s%s%s depends on %s\n"
            term.esc_bold n1 term.esc_end n2)
        (List.combine cycle (List.tl cycle @ [List.hd cycle]));
      cycle @ cantbuild
    end else begin
      Printf.eprintf
        "%sERROR%s: the following packages are %smissing%s:\n"
        term.esc_red_text term.esc_end  term.esc_bold term.esc_end;
      List.iter (fun (name,_) ->
        Printf.eprintf "  - %s%s%s\n" term.esc_bold name term.esc_end
      ) missing_roots;
      List.map fst missing_roots @ cantbuild
    end
  in
  let cantbuild =
    if pj.project_incomplete = [||] then cantbuild
    else begin
      let additional =
        List.filter
          (fun pk -> pk.package_source_kind <> "meta"
                     && not (List.mem pk.package_name cantbuild))
          (Array.to_list pj.project_incomplete)
      in
      if additional <> [] then
        Printf.eprintf
          "Additional packages %s can't be built.\n"
          (String.concat ", "
             (List.map (fun pk -> Printf.sprintf "%s%s%s"
                  term.esc_bold pk.package_name term.esc_end)
                additional));
      List.map (fun pk -> pk.package_name) additional @ cantbuild
    end
  in
  if cantbuild <> [] then
    (* TODO: we should (exit 1) only if one of the provided targets
cannot be built ! *)
    ()

let do_init_project_building cfg project_dir pj =
  let build_dir_basename = !build_dir_basename_arg in

  let build_dir_filename = (* absolute_filename *) build_dir_basename in

  let host = Printf.sprintf "%s-%s-%s"
      cfg.ocaml_system cfg.ocaml_architecture cfg.ocaml_version in

  let build_dir_filename =
    match !arch_arg with
      ArchAuto -> Filename.concat build_dir_filename host
    | Arch host -> Filename.concat build_dir_filename host
    | ArchNone -> build_dir_filename
  in

  BuildMisc.safe_mkdir build_dir_filename;

  time_step "Saving raw project info...";
  BuildOCP.save_project_state pj
    (File.add_basename (File.of_string build_dir_filename) "ocp.ocpx");
  time_step "   Done saving raw project info";


  let b =
    BuildEngineContext.create (File.to_string project_dir)
      build_dir_filename in

  b.stop_on_error_arg <- !stop_on_error_arg;

  BuildOCamlRules.create b pj !tests_arg;

  if !list_byte_targets_arg then begin
    Printf.eprintf "Bytecode targets:\n";
    StringMap.iter (fun _ lib ->
      if lib.lib_byte_targets <> [] then begin
        List.iter (fun (target, kind) ->
          Printf.eprintf "\t%s\t->\t%s\n" lib.lib_name target.file_basename)
          lib.lib_byte_targets;
      end) !packages_by_name;
    Printf.eprintf "%!"
  end;

  if !list_asm_targets_arg then begin
    Printf.eprintf "Native targets:\n";
    StringMap.iter (fun _ lib ->
      if lib.lib_asm_targets <> [] then begin
        List.iter (fun (target, kind) ->
          Printf.eprintf "\t%s\t->\t%s\n" lib.lib_name target.file_basename)
          lib.lib_asm_targets;
      end) !packages_by_name;
    Printf.eprintf "%!"
  end;
  b





let do_compile b cin ncores projects =
  (* build the list of targets *)
  let targets = ref [] in
  let map = ref StringMap.empty in
  let rec add_project_targets lib =
    if not lib.lib_installed &&
       (!tests_arg || lib.lib_type <> TestPackage) &&
       not (StringMap.mem lib.lib_name !map) then begin
      if cin.cin_bytecode then
        targets := List.map fst lib.lib_byte_targets @ !targets;
      if cin.cin_native then
        targets := List.map fst lib.lib_asm_targets @ !targets;
      map := StringMap.add lib.lib_name lib !map;
      List.iter (fun dep ->
        if dep.dep_link || dep.dep_syntax then
          add_project_targets dep.dep_project
      ) lib.lib_requires
    end
  in
  List.iter add_project_targets projects;

  if !targets = [] && not !tests_arg then begin
    Printf.eprintf "Error: project contains no targets\n%!";
    Printf.eprintf "\tAre your .ocp files empty ?\n%!";
    exit 2
  end;

  (*
        List.iter (fun s ->
        Printf.eprintf "TARGET %S\n%!" (File.to_string s.file_file)
        ) !targets;
      *)



  if !targets <> [] then begin
    time_step "Initializing build engine...";
    begin

      try
        BuildEngine.init b !targets
      with BuildEngine.MissingSourceWithNoBuildingRule (r, filename) ->
        let (rule_filename, rule_loc, rule_name) = r.rule_loc in
        BuildMisc.print_loc rule_filename rule_loc;
        Printf.eprintf "Error: in project \"%s\", the source filename\n"
          rule_name;
        Printf.eprintf "\t\"%s\" does not exist\n" filename;
        BuildEngineRules.print_rule r;
        exit 2
    end;
    time_step "   Build Engine Initialized";
    time_step "Checking remaining artefacts...";
    let orphans = BuildEngine.sanitize b !delete_orphans_arg
        (fun basename ->
          match basename with
            "_tests" -> true
          | _ -> false)
    in
    if orphans > 0 then begin
      Printf.eprintf "Error: found %d orphan files in %s. You must remove them.\n" orphans !build_dir_basename_arg;
      Printf.eprintf "\n";
      Printf.eprintf "   You can add the -sanitize argument to automatically remove\n";
      Printf.eprintf "   orphan files\n";
      Printf.eprintf "\n";
      exit 2;
    end else
    if orphans < 0 then
      Printf.eprintf
        "Warning: deleted %d orphan files in %s\n" (-orphans) !build_dir_basename_arg;
    time_step "   Done sanitizing";

    time_step "Building packages...";
    let _max_nslots = BuildEngine.parallel_loop b ncores
    in
    time_step "   Done building packages";

    let errors = BuildEngine.fatal_errors() @
        BuildEngineDisplay.errors() in
    let t1 = Unix.gettimeofday () in

    let nerrors = List.length errors in
    Printf.eprintf
      "%s in %.2fs. %d jobs (parallelism %.1fx), %d files generated.\n%!"
      (if errors = [] then
         if term.esc_ansi then
           Printf.sprintf "%sBuild Successful%s"
             term.esc_green_text term.esc_end
         else "Build Successful"
       else
         Printf.sprintf "%s%d error%s%s" term.esc_red_text
           nerrors
           (if nerrors > 1 then "s" else "")
           term.esc_end)
      (t1 -. t0)
      !BuildEngine.stats_command_executed
      (!BuildEngine.stats_total_time /. (t1 -. t0))
      !BuildEngine.stats_files_generated;
    if errors <> [] (* && not (verbose 1 && term.esc_ansi) *) then begin
      Printf.eprintf "Error log:\n";
      List.iter (fun lines ->
        Printf.eprintf "Error:\n";
        List.iter (fun line ->
          Printf.eprintf "%s\n" line
        ) lines
      ) errors;
    end;
    if errors <> [] then exit 2
  end;
  Printf.eprintf "%!"



let do_read_env p =

  let cin = p.cin in
  let cout = p.cout in
  let cfg = p.cfg in

  BuildOCamlConfig.set_global_config cout;

  (* Don't modify default values from now on, since they have been included
     in the default configuration ! *)

  let env_ocp_dirs = ref cin.cin_ocps_dirnames in
  let env_ocp_files = ref [] in
  if cin.cin_ocps_in_ocamllib then
    env_ocp_dirs := cfg.ocaml_ocamllib :: !env_ocp_dirs;

  time_step "Scanning env for .ocp files...";
  List.iter (fun dir ->
    if verbose 3 then
      Printf.eprintf "Scanning installed .ocp files in %S\n%!" dir;
    let dir = File.of_string dir in
    env_ocp_files := ( BuildOCP.scan_root dir) @ !env_ocp_files
  ) !env_ocp_dirs;
  time_step "   Done scanning env for .ocp files";

  let state = BuildOCP.init_packages () in
  time_step "Loading METAs...";
  List.iter (fun dirname ->
    BuildOCamlMeta.load_META_files state cfg dirname
  ) cout.cout_meta_dirnames;

  time_step "   Done Loading METAs";

  time_step "Loading .ocp files from env...";

  let _nerrors1 =
    let config = BuildOCP.generated_config () in
    BuildOCP.load_ocp_files config state  !env_ocp_files
  in

  time_step "   Done Loading .ocp files from env";

  state

let do_prepare_build p =

  let state = do_read_env p in

  let targets = List.rev !targets_arg in
  time_step "Arguments parsed.";

  if !query_global then move_to_project := false;

  let project_dir = p.project_dir in
  let cin = p.cin in
  let cfg = p.cfg in
  let install_where = p.install_where in

  if !list_installed_arg then begin
    print_installed install_where;
    exit 0
  end;

  let uninstall_state = BuildOCamlInstall.uninstall_init install_where in

  if !uninstall_arg && targets <> [] then begin

    List.iter (BuildOCamlInstall.uninstall_by_name uninstall_state) targets;
    BuildOCamlInstall.uninstall_finish uninstall_state;
    exit 0
  end;

  begin match !query_install_dir with
      None -> ()
    | Some p ->
      let open BuildOCamlInstall in
      List.iter (fun un ->
        if un.un_name = p then begin
          Printf.printf "%s\n%!" un.un_directory;
          exit 0
        end
      ) (BuildOCamlInstall.list_installed install_where);
      Printf.eprintf "Package %S is not installed\n%!" p;
      exit 2
  end;

(*
  if !move_to_project then begin

      match project_dir with
      | None ->

        (* if we arrive here, it means we really needed ocp-build.root *)
        Printf.eprintf "Fatal error: no ocp-build.root file found.\n%!";
        Printf.eprintf
          "\tYou can use the -init option at the root of the project\n";
        Printf.eprintf "\tto create the initial file.\n%!";
        exit 2

      | Some project_dir ->
*)
        let dir = File.to_string project_dir in
        if Unix.getcwd () <> dir then begin
          Unix.chdir dir;
          Printf.fprintf stdout "ocp-build: Entering directory `%s'\n%!"
            (File.to_string project_dir);
          add_finally (fun () ->
            Printf.printf
              "ocp-build: Leaving directory `%s'\n%!"
              (File.to_string project_dir)
          )
        end;
        do_load_project_files cin project_dir state;

(*    end; *)

    (* [ocp-build configure] stops here, so it will not scan
       for .ocp files at this point. Instead, it will be done the
       first time the project is compiled, because [root_files] is
       empty. *)

    if !configure_arg then save_project := true;

    if !save_project then begin
      Printf.fprintf stderr "Updating ocp-build.root\n%!";
      BuildOptions.must_save_project ()
    end;


    if !conf_arg || !distrib_arg || !autogen_arg then exit 0;

    let use_digests = cin.cin_digest in

    if use_digests then BuildEngineMtime.use_digests true;

    time_step "Sorting packages...";
    let pj = BuildOCP.verify_packages state in

    time_step "   Done sorting packages";

(*
    do_reply_to_queries pj;
*)

    if !query_global then begin
      Printf.eprintf "Error: reached query-global end point.\n%!";
      exit 0
    end;

    BuildOptions.maybe_save ();

    if !configure_arg then exit 0;

    if !clean_arg then begin
      Printf.eprintf "Removing build target directory\n%!";

      BuildActions.delete_file_or_directory !build_dir_basename_arg;
      exit 0;
    end;

    if verbose 1 && term.esc_ansi then
      do_print_fancy_project_info pj
    else
      do_print_project_info pj;

(*
    match project_dir with
      None -> assert false
    | Some project_dir ->
    (*        let root_dir = File.dirname root_file in *)
*)

      let b = do_init_project_building cfg project_dir pj in


      let projects =
        (* build the list of projects considered by the current command *)
        let projects = ref [] in
        match targets with
          [] ->
          StringMap.iter (fun _ pj ->
              projects := pj :: !projects) !packages_by_name;
          !projects
        | list ->
          List.iter (fun name ->
              try
                let pj = StringMap.find name !packages_by_name in
                projects := pj :: !projects
              with Not_found ->
                Printf.eprintf
                  "Error: Could not find target project %s\n%!" name;
                exit 2
            ) list;
          !projects
      in

      (b, projects)

let get_ncores cin =
  let ncores = cin.cin_njobs in
  if ncores < 1 then
    BuildConfig.number_of_cores () + 1
  else
    ncores


let do_build p =
  let (b, projects) = do_prepare_build p in
  do_compile b p.cin (get_ncores p.cin) projects;
  (b, projects)


let action () =
(*
  if !init_arg && not (Sys.file_exists "ocp-build.root") then begin
    let oc = open_out "ocp-build.root" in
    close_out oc
  end;
  if !root_arg then exit 0;
*)
  let p = BuildActions.load_project () in
  let (_b, _projects) = do_build p in
  ()

let arg_list = [
  (* This option should be shared with -install and -tests, no ? *)
  "-arch", Arg.String (fun s ->
    arch_arg := Arch ("_other_archs/" ^ s)),
  "ARCH Set arch sub-directory of _obuild";
] @ arg_list1

let add_synomyms arg_list1 synonyms =
  arg_list1 @ List.map (fun (s1, s2) ->
    let rec iter list =
      match list with
      [] -> assert false
      | (s, action, help) :: tail when s = s2 -> (s1, action, help)
      | _ :: tail -> iter tail
    in
    iter arg_list1
  ) synonyms

let arg_list = add_synomyms arg_list
    [ "-v", "-verbosity";
      "-j", "-njobs";
    ]

let arg_usage = [ "Build" ]

let subcommand = {
  sub_name = "build";
  sub_help = "Build the project";
  sub_arg_list = arg_list;
  sub_arg_anon = Some arg_anon;
  sub_arg_usage = arg_usage;
  sub_action = action;
}
