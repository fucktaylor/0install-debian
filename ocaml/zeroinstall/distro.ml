(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

open General
open Support
open Support.Common
module FeedAttr = Constants.FeedAttr
module U = Support.Utils
module Q = Support.Qdom

exception Fallback_to_Python

class virtual distribution config =
  let system = config.system in
  object (self)
    val virtual distro_name : string
    val system_paths = ["/usr/bin"; "/bin"; "/usr/sbin"; "/sbin"]

    val packagekit = !Packagekit.packagekit config

    (** Can we use packages for this distribution? For example, MacPortsDistribution can use "MacPorts" and "Darwin" packages. *)
    method match_name name = (name = distro_name)

    (** Test whether this <selection> element is still valid *)
    method virtual is_installed : Support.Qdom.element -> bool

    method virtual get_all_package_impls : Feed.feed -> Feed.implementation StringMap.t option

    (** Called when an installed package is added, or when installation completes. This is useful to fix up the main value.
        The default implementation checks that main exists, and searches [system_paths] for
        it if not. *)
    method private fixup_main props =
      let open Feed in
      match get_command_opt "run" props.commands with
      | None -> ()
      | Some run ->
          match ZI.get_attribute_opt "path" run.command_qdom with
          | None -> ()
          | Some path ->
              if Filename.is_relative path || not (system#file_exists path) then (
                (* Need to search for the binary *)
                let basename = Filename.basename path in
                let basename = if on_windows && not (Filename.check_suffix path ".exe") then basename ^ ".exe" else basename in
                let check_path d =
                  let path = d +/ basename in
                  if system#file_exists path then (
                    log_info "Found %s by searching system paths" path;
                    Qdom.set_attribute "path" path run.command_qdom;
                    true
                  ) else false in
                if not @@ List.exists check_path system_paths then
                  log_info "Binary '%s' not found in any system path (checked %s)" basename (String.concat ", " system_paths)
              )

    (** Helper for [get_package_impls]. *)
    method private add_package_implementation elem props ~id ~version ~machine ~extra_attrs ~is_installed map =
      if is_installed then self#fixup_main props;
      let new_attrs = ref props.Feed.attrs in
      let set name value =
        new_attrs := Feed.AttrMap.add ("", name) value !new_attrs in
      set "id" id;
      set "version" version;
      set "from-feed" @@ "distribution:" ^ (Feed.AttrMap.find ("", "from-feed") !new_attrs);
      List.iter (fun (n, v) -> set n v) extra_attrs;
      let open Feed in
      let impl = {
        qdom = elem;
        os = None;
        machine = Arch.none_if_star machine;
        stability = Packaged;
        props = {props with attrs = !new_attrs};
        parsed_version = Versions.parse_version version;
        impl_type = PackageImpl { package_installed = is_installed; package_distro = distro_name; retrieval_method = None };
      } in
      StringMap.add id impl map

    (** Check (asynchronously) for available but currently uninstalled candidates. Once the returned
        promise resolves, the candidates should be included in the response from get_package_impls. *)
    method virtual check_for_candidates : Feed.feed -> unit Lwt.t

    method install_distro_packages (ui:Ui.ui_handler) typ items : [ `ok | `cancel ] Lwt.t =
      match typ with
      | "packagekit" ->
          begin match_lwt packagekit#install_packages ui items with
          | `cancel -> Lwt.return `cancel
          | `ok ->
              items |> List.iter (fun (impl, _rm) ->
                self#fixup_main impl.Feed.props;
              );
              Lwt.return `ok end
      | _ ->
          let names = items |> List.map (fun (_impl, rm) -> snd rm.Feed.distro_install_info) in
          ui#confirm (Printf.sprintf
            "This program depends on some packages that are available through your distribution. \
             Please install them manually using %s and try again. Or, install 'packagekit' and I can \
             use that to install things. The packages are:\n\n- %s" typ (String.concat "\n- " names))
  end

let package_impl_from_json ~prefix elem props json =
  let open Feed in
  let pkg_type = ref @@ { package_installed = false; package_distro = "unknown"; retrieval_method = None } in
  let new_props = ref props in
  let pkg = ref {
    qdom = elem;
    os = None;
    machine = None;
    stability = Packaged;
    props;                                (* (gets overwritten later) *)
    parsed_version = Versions.dummy;
    impl_type = PackageImpl !pkg_type;    (* (gets overwritten later) *)
  } in
  let new_attrs = ref props.Feed.attrs in

  let set name value =
    new_attrs := Feed.AttrMap.add ("", name) value !new_attrs in

  let master_feed = Feed.AttrMap.find ("", "from-feed") !new_attrs in
  set "from-feed" @@ "distribution:" ^ master_feed;
  set "stability" "packaged";   (* The GUI likes to know the upstream stability too *)

  let fixup_main path =
    (* The Python code might add or modify the main executable path. *)
    let run_command =
      try
        let command = StringMap.find "run" !new_props.commands in
        let new_elem = {command.command_qdom with Qdom.attrs = command.command_qdom.Qdom.attrs} in
        Qdom.set_attribute "path" path new_elem;
        {command with command_qdom = new_elem}
      with Not_found ->
        make_command elem.Qdom.doc "run" path in
    new_props := {!new_props with commands = StringMap.add "run" run_command !new_props.commands} in

  match json with
  | `Assoc lst ->
      ListLabels.iter lst ~f:(function
        | ("id", `String v) -> set "id" (prefix ^ v)
        | ("version", `String v) -> set "version" v; pkg := {!pkg with parsed_version = Versions.parse_version v}
        | ("machine", `String v) -> pkg := {!pkg with machine = Arch.none_if_star v}
        | ("machine", `Null) -> ()
        | ("is_installed", `Bool v) -> pkg_type := {!pkg_type with package_installed = v}
        | ("distro", `String v) -> pkg_type := {!pkg_type with package_distro = v}
        | ("quick-test-file", `String v) -> set "quick-test-file" v
        | ("quick-test-mtime", `String v) -> set "quick-test-mtime" v
        | ("main", `String v) -> fixup_main v
        | (k, v) -> raise_safe "Bad JSON response '%s=%s'" k (Yojson.Basic.to_string v)
      );
      {!pkg with impl_type = PackageImpl !pkg_type; props = {!new_props with attrs = !new_attrs}}
  | _ -> raise_safe "Bad JSON: %s" (Yojson.Basic.to_string json)

let package_impl_from_packagekit id elem props distro_name info =
  let {Packagekit.version; Packagekit.machine; Packagekit.installed; Packagekit.retrieval_method} = info in
  let open Feed in

  let master_feed = Feed.AttrMap.find ("", "from-feed") props.attrs in
  let set name value attrs = attrs |> Feed.AttrMap.add ("", name) value in

  let attrs = props.attrs
  |> set FeedAttr.id id
  |> set FeedAttr.from_feed @@ "distribution:" ^ master_feed
  |> set FeedAttr.stability "packaged"   (* The GUI likes to know the upstream stability too *)
  |> set FeedAttr.version (Versions.format_version version);
  in

  let props = {props with attrs} in

  let pkg_type = {
    package_installed = installed;
    package_distro = distro_name;
    retrieval_method = Some retrieval_method
  } in
  let pkg = {
    qdom = elem;
    os = None;
    machine;
    stability = Packaged;
    props;
    parsed_version = version;
    impl_type = PackageImpl pkg_type;
  } in
  pkg

(** Return the <package-implementation> elements that best match this distribution. *)
let get_matching_package_impls (distro : #distribution) feed =
  let best_score = ref 0 in
  let best_impls = ref [] in
  ListLabels.iter feed.Feed.package_implementations ~f:(function (elem, _) as package_impl ->
    let distributions = default "" @@ ZI.get_attribute_opt "distributions" elem in
    let distro_names = Str.split_delim U.re_space distributions in
    let score_this_item =
      if distro_names = [] then 1                                 (* Generic <package-implementation>; no distribution specified *)
      else if List.exists distro#match_name distro_names then 2   (* Element specifies it matches this distribution *)
      else 0 in                                                   (* Element's distributions do not match *)
    if score_this_item > !best_score then (
      best_score := score_this_item;
      best_impls := []
    );
    if score_this_item = !best_score then (
      best_impls := package_impl :: !best_impls
    )
  );
  !best_impls

let make_restricts_distro doc iface_uri distros =
  let elem = ZI.make doc "restricts" in
  let open Feed in {
    dep_qdom = elem;
    dep_importance = Dep_restricts;
    dep_iface = iface_uri;
    dep_restrictions = [make_distribtion_restriction distros];
    dep_required_commands = [];
    dep_if_os = None;
    dep_use = None;
  }

(** Set quick-test-file and quick-test-mtime from path. *)
let get_quick_test_attrs path =
  let mtime = (Unix.stat path).Unix.st_mtime in
  Feed.AttrMap.singleton ("", "quick-test-file") path |>
  Feed.AttrMap.add ("", "quick-test-mtime") (Printf.sprintf "%.0f" mtime)

class virtual python_fallback_distribution (slave:Python.slave) python_name ctor_args =
  let make_host_impl path version ?(commands=StringMap.empty) ?(requires=[]) from_feed id =
    let host_machine = slave#config.system#platform in
    let open Feed in
    let props = {
      attrs = get_quick_test_attrs path
        |> AttrMap.add ("", FeedAttr.from_feed) (Feed_url.format_url (`distribution_feed from_feed))
        |> AttrMap.add ("", FeedAttr.id) id
        |> AttrMap.add ("", FeedAttr.stability) "packaged"
        |> AttrMap.add ("", FeedAttr.version) version;
      requires;
      bindings = [];
      commands;
    } in {
      qdom = ZI.make_root "host-package-implementation";
      props;
      stability = Packaged;
      os = None;
      machine = Some host_machine.Platform.machine;       (* (hopefully) *)
      parsed_version = Versions.parse_version version;
      impl_type = PackageImpl {
        package_distro = "host";
        package_installed = true;
        retrieval_method = None;
      }
    } in

  let did_init = ref false in

  let invoke ?xml op args process =
    lwt () =
      if not !did_init then (
        let ctor_args = ctor_args |> List.map (fun a -> `String a) in
        let r = slave#invoke_async (`List [`String "init-distro"; `String python_name; `List ctor_args]) Python.expect_null in
        did_init := true;
        r
      ) else Lwt.return () in
    slave#invoke_async ?xml (`List (`String op :: args)) process in

  let fake_host_doc = (ZI.make_root "<fake-host-root>").Qdom.doc in

  let get_host_impls map = function
    | `remote_feed "http://repo.roscidus.com/python/python" as url ->
        (* Hack: we can support Python on platforms with unsupported package managers
           by adding the implementation of Python running the slave now to the list. *)
        let path, version =
          invoke "get-python-details" [] (function
            | `List [`String path; `String version] -> (path, version)
            | json -> raise_safe "Bad JSON: %s" (Yojson.Basic.to_string json)
          ) |> Lwt_main.run in
        let id = "package:host:python:" ^ version in
        let run = ZI.make_root "command" in
        run |> Q.set_attribute "name" "run";
        run |> Q.set_attribute "path" path;
        let commands = StringMap.singleton "run" Feed.({command_qdom = run; command_requires = []}) in
        map |> StringMap.add id @@ make_host_impl path version ~commands url id
    | `remote_feed "http://repo.roscidus.com/python/python-gobject" as url ->
        let path, version =
          invoke "get-gobject-details" [] (function
            | `List [`String path; `String version] -> (path, version)
            | json -> raise_safe "Bad JSON: %s" (Yojson.Basic.to_string json)
          ) |> Lwt_main.run in
        let id = "package:host:python-gobject:" ^ version in
        let requires = [make_restricts_distro fake_host_doc "http://repo.roscidus.com/python/python" "host"] in
        map |> StringMap.add id @@ make_host_impl path version ~requires url id
    | _ -> map in

  let to_impls ?(prefix="") map (elem, props) = function
    | `List pkgs ->
        let add_impl map pkg =
          let impl = package_impl_from_json ~prefix elem props pkg in
          let id = Feed.get_attr_ex FeedAttr.id impl in
          map |> StringMap.add id impl in
        List.fold_left add_impl map pkgs
    | _ -> raise_safe "Not a group list" in

  object (self)
    inherit distribution slave#config

    (* Should we check for Python and GObject manually? Use [false] if the package manager
     * can be relied upon to find them. *)
    val virtual check_host_python : bool

    (** All IDs will start with this string (e.g. "package:deb") *)
    val virtual id_prefix : string

    method is_installed elem =
      log_info "No is_installed implementation for '%s'; using slow Python fallback instead!" distro_name;
      let master_feed =
        match ZI.get_attribute_opt FeedAttr.from_feed elem with
        | None -> ZI.get_attribute FeedAttr.interface elem |> Feed_url.parse_non_distro (* (for very old selections documents) *)
        | Some from_feed ->
            match Feed_url.parse from_feed with
            | `distribution_feed master_feed -> master_feed
            | `local_feed _ | `remote_feed _ -> assert false in
      match Feed_cache.get_cached_feed slave#config master_feed with
      | None -> false
      | Some master_feed ->
          let wanted_id = ZI.get_attribute FeedAttr.id elem in
          let impls = self#get_all_package_impls master_feed |? lazy StringMap.empty in
          let is_installed impl =
            match impl.Feed.impl_type with
            | Feed.PackageImpl {Feed.package_installed; _} -> package_installed
            | _ -> assert false in
          try is_installed (StringMap.find wanted_id impls)
          with Not_found -> false

    method get_all_package_impls feed =
      match get_matching_package_impls self feed with
      | [] -> None
      | matches ->
          let host_impls =
            if check_host_python then get_host_impls StringMap.empty (feed.Feed.url)
            else StringMap.empty in
          let impls = List.fold_left self#add_candidates host_impls matches in
          try
            Some (List.fold_left self#get_package_impls impls matches)
          with Fallback_to_Python ->
            let fake_feed = ZI.make feed.Feed.root.Q.doc "interface" in
            fake_feed.Q.child_nodes <- List.map fst matches;

            invoke ~xml:fake_feed "get-package-impls" [`String (Feed_url.format_url feed.Feed.url)] (function
              | `List pkg_groups ->
                  let all_impls = List.fold_left2 to_impls impls matches pkg_groups in
                  Some all_impls
              | _ -> raise_safe "Invalid response"
            ) |> Lwt_main.run

    (** Get all installed implementations, plus any candidates previously found by [check_for_candidates].
     * Do not add PackageImpl implementations here. They get added automatically. *)
    method private get_package_impls _ _ : (Feed.implementation StringMap.t) = raise Fallback_to_Python

    (* Add candidates even in the Python-fallback case (this might go away later).
     * By default, we add any PackageKit candidates found by [check_for_candidates]. *)
    method private add_candidates map (elem, props) =
      let package_name = ZI.get_attribute "package" elem in

      let add map info =
        let id = Printf.sprintf "%s:%s:%s:%s" id_prefix package_name
          (Versions.format_version info.Packagekit.version) (default "*" info.Packagekit.machine) in
        let impl = package_impl_from_packagekit id elem props distro_name info in
        StringMap.add id impl map in
      packagekit#get_impls package_name |> List.fold_left add map

    method check_for_candidates feed =
      match get_matching_package_impls self feed with
      | [] -> Lwt.return ()
      | matches ->
          lwt available = packagekit#is_available in
          if available then (
            let package_names = matches |> List.map (fun (elem, _props) -> ZI.get_attribute "package" elem) in
            packagekit#check_for_candidates package_names
          ) else Lwt.return ()

    method private invoke = invoke
  end

class generic_distribution slave =
  object
    inherit python_fallback_distribution slave "Distribution" []
    val check_host_python = true
    val distro_name = "fallback"
    val id_prefix = "package:fallback"
  end

let try_cleanup_distro_version_warn version package_name =
  match Versions.try_cleanup_distro_version version with
  | None -> log_warning "Can't parse distribution version '%s' for package '%s'" version package_name; None
  | version -> version

(** A simple cache for storing key-value pairs on disk. Distributions may wish to use this to record the
    version(s) of each distribution package currently installed. *)
module Cache =
  struct

    type cache_data = {
      mutable mtime : Int64.t;
      mutable size : int;
      mutable rev : int;
      mutable contents : (string, string) Hashtbl.t;
    }

    let re_colon_space = Str.regexp_string ": "

    (* Note: [format_version] doesn't make much sense. If the format changes, just use a different [cache_leaf],
       otherwise you'll be fighting with other versions of 0install.
       The [old_format] used different separator characters.
       *)
    class cache (config:General.config) (cache_leaf:string) (source:filepath) (format_version:int) ~(old_format:bool) =
      let re_metadata_sep = if old_format then re_colon_space else U.re_equals
      and re_key_value_sep = if old_format then U.re_tab else U.re_equals
      in
      object (self)
        (* The status of the cache when we loaded it. *)
        val data = { mtime = 0L; size = -1; rev = -1; contents = Hashtbl.create 10 }

        val cache_path = (Basedir.save_path config.system (config_site +/ config_prog) config.basedirs.Basedir.cache) +/ cache_leaf

        (** Reload the values from disk (even if they're out-of-date). *)
        method load_cache =
          data.mtime <- -1L;
          data.size <- -1;
          data.rev <- -1;
          Hashtbl.clear data.contents;

          if Sys.file_exists cache_path then (
            let load_cache ch =
              let headers = ref true in
              while !headers do
                match input_line ch with
                | "" -> headers := false
                | line ->
                    (* log_info "Cache header: %s" line; *)
                    match Utils.split_pair re_metadata_sep line with
                    | ("mtime", mtime) -> data.mtime <- Int64.of_string mtime
                    | ("size", size) -> data.size <- int_of_string size
                    | ("version", rev) when old_format -> data.rev <- int_of_string rev
                    | ("format", rev) when not old_format -> data.rev <- int_of_string rev
                    | _ -> ()
              done;

              try
                while true do
                  let line = input_line ch in
                  let (key, value) = Utils.split_pair re_key_value_sep line in
                  Hashtbl.add data.contents key value   (* note: adds to existing list of packages for this key *)
                done
              with End_of_file -> ()

              in
            config.system#with_open_in [Open_rdonly; Open_text] 0 cache_path load_cache
          )

        (** Check cache is still up-to-date. Clear it not. *)
        method ensure_valid =
          match config.system#stat source with
          | None when data.size = -1 -> ()    (* Still doesn't exist - no problem *)
          | None -> raise Fallback_to_Python  (* Disappeared (shouldn't happen) *)
          | Some info ->
              if data.mtime <> Int64.of_float info.Unix.st_mtime then (
                log_info "Modification time of %s has changed; invalidating cache" source;
                raise Fallback_to_Python
              ) else if data.size <> info.Unix.st_size then (
                log_info "Size of %s has changed; invalidating cache" source;
                raise Fallback_to_Python
              ) else if data.rev <> format_version then (
                log_info "Format of cache %s has changed; invalidating cache" cache_path;
                raise Fallback_to_Python
              )

        method get (key:string) : string list =
          self#ensure_valid;
          Hashtbl.find_all data.contents key

        initializer self#load_cache
      end
  end

(** Lookup [elem]'s package in the cache. Generate the ID(s) for the cached implementations and check that one of them
    matches the [id] attribute on [elem].
    Returns [false] if the cache is out-of-date. *)
let check_cache id_prefix elem cache =
  match ZI.get_attribute_opt "package" elem with
  | None ->
      Qdom.log_elem Support.Logging.Warning "Missing 'package' attribute" elem;
      false
  | Some package ->
      let sel_id = ZI.get_attribute "id" elem in
      let matches data =
          let installed_version, machine = Utils.split_pair U.re_tab data in
          let installed_id = Printf.sprintf "%s:%s:%s:%s" id_prefix package installed_version machine in
          (* log_warning "Want %s %s, have %s" package sel_id installed_id; *)
          sel_id = installed_id in
      List.exists matches (cache#get package)

module Debian = struct
  let dpkg_db_status = "/var/lib/dpkg/status"

  type apt_cache_entry = {
    version : string;
    machine : string;
    size : Int64.t option;
  }

  class debian_distribution ?(status_file=dpkg_db_status) config slave =
    let apt_cache = Hashtbl.create 10 in
    let system = config.system in

    (* Populate [apt_cache] with the results. *)
    let query_apt_cache package_names =
      package_names |> Lwt_list.iter_s (fun package ->
        (* Check to see whether we could get a newer version using apt-get *)
        lwt result =
          try_lwt
            lwt out = Lwt_process.pread ~stderr:`Dev_null (U.make_command system ["apt-cache"; "show"; "--no-all-versions"; "--"; package]) in
            let machine = ref None in
            let version = ref None in
            let size = ref None in
            let stream = U.stream_of_lines out in
            begin try
              while true do
                let line = Stream.next stream |> trim in
                if U.starts_with line "Version: " then (
                  version := try_cleanup_distro_version_warn (U.string_tail line 9 |> trim) package
                ) else if U.starts_with line "Architecture: " then (
                  machine := Some (Support.System.canonical_machine (U.string_tail line 14 |> trim))
                ) else if U.starts_with line "Size: " then (
                  size := Some (Int64.of_string (U.string_tail line 6 |> trim))
                )
              done
            with Stream.Failure -> () end;
            match !version, !machine with
            | Some version, Some machine -> Lwt.return (Some {version; machine; size = !size})
            | _ -> Lwt.return None
          with ex ->
            log_warning ~ex "'apt-cache show %s' failed" package;
            Lwt.return None in
        (* (multi-arch support? can there be multiple candidates?) *)
        Hashtbl.replace apt_cache package result;
        Lwt.return ()
      ) in

    object (self : #distribution)
      inherit python_fallback_distribution slave "DebianDistribution" [status_file] as super
      val check_host_python = false

      val distro_name = "Debian"
      val id_prefix = "package:deb"
      val cache = new Cache.cache config "dpkg-status.cache" dpkg_db_status 2 ~old_format:false

      method! is_installed elem =
        try check_cache id_prefix elem cache
        with Fallback_to_Python -> super#is_installed elem

      method! private get_package_impls map (elem, props) =
        let package_name = ZI.get_attribute "package" elem in
        let process map cached_info =
          match Str.split_delim U.re_tab cached_info with
          | [version; machine] ->
              let id = Printf.sprintf "package:deb:%s:%s:%s" package_name version machine in
              map |> self#add_package_implementation elem props ~is_installed:true
                ~id ~version ~machine ~extra_attrs:[]
          | _ ->
              log_warning "Unknown cache line format for '%s': %s" package_name cached_info;
              raise Fallback_to_Python
        in

        match cache#get package_name with
        | [] -> raise Fallback_to_Python      (* We don't know anything about this package *)
        | ["-"] -> map                        (* We know the package isn't installed *)
        | infos -> List.fold_left process map infos

    method! check_for_candidates feed =
      match get_matching_package_impls self feed with
      | [] -> Lwt.return ()
      | matches ->
          lwt available = packagekit#is_available in
          if available then (
            let package_names = matches |> List.map (fun (elem, _props) -> ZI.get_attribute "package" elem) in
            packagekit#check_for_candidates package_names
          ) else (
            (* No PackageKit. Use apt-cache directly. *)
            query_apt_cache (matches |> List.map (fun (elem, _props) -> (ZI.get_attribute "package" elem)))
          )

    method! private add_candidates map (elem, props) =
      let map = super#add_candidates map (elem, props) in

      (* Add apt-cache candidates (there won't be any if we used PackageKit) *)
      let package = ZI.get_attribute "package" elem in
      let entry = try Hashtbl.find apt_cache package with Not_found -> None in
      match entry with
      | Some {version; machine; size = _} ->
          let id = Printf.sprintf "package:deb:%s:%s:%s" package version machine in
          map |> self#add_package_implementation elem props ~is_installed:false ~id ~version ~machine ~extra_attrs:[]
      | None -> map
    end
end

module RPM = struct
  let rpm_db_packages = "/var/lib/rpm/Packages"

  class rpm_distribution ?(status_file = rpm_db_packages) config slave =
    object
      inherit python_fallback_distribution slave "RPMDistribution" [status_file] as super
      val check_host_python = false

      val distro_name = "RPM"
      val id_prefix = "package:rpm"
      val cache = new Cache.cache config "rpm-status.cache" rpm_db_packages 2 ~old_format:true

      method! is_installed elem =
        try check_cache id_prefix elem cache
        with Fallback_to_Python -> super#is_installed elem
    end
end

module ArchLinux = struct
  let arch_db = "/var/lib/pacman"

  class arch_distribution ?(arch_db=arch_db) config slave =
    let packages_dir = arch_db ^ "/local" in
    let parse_dirname entry =
      try
        let build_dash = String.rindex entry '-' in
        let version_dash = String.rindex_from entry (build_dash - 1) '-' in
        Some (String.sub entry 0 version_dash,
              U.string_tail entry (version_dash + 1))
      with Not_found -> None in

    let get_arch desc_path =
      let arch = ref None in
      let read ch =
        try
          while !arch = None do
            let line = input_line ch in
            if line = "%ARCH%" then
              arch := Some (trim (input_line ch))
          done
        with End_of_file -> () in
      config.system#with_open_in [Open_rdonly; Open_text] 0 desc_path read;
      !arch in

    let entries = ref (-1.0, StringMap.empty) in
    let get_entries () =
      let (last_read, items) = !entries in
      match config.system#stat packages_dir with
      | Some info when info.Unix.st_mtime > last_read -> (
          match config.system#readdir packages_dir with
          | Success items ->
              let add map entry =
                match parse_dirname entry with
                | Some (name, version) -> StringMap.add name version map
                | None -> map in
              let new_items = Array.fold_left add StringMap.empty items in
              entries := (info.Unix.st_mtime, new_items);
              new_items
          | Problem ex ->
              log_warning ~ex "Can't read packages dir '%s'!" packages_dir;
              items
      )
      | _ -> items in

    object (self : #distribution)
      inherit python_fallback_distribution slave "ArchDistribution" [arch_db]
      val check_host_python = false

      val distro_name = "Arch"
      val id_prefix = "package:arch"

      (* We should never get here for an installed package, because we always set quick-test-* *)
      method! is_installed _elem = false

      method! private get_package_impls map (elem, props) =
        let package_name = ZI.get_attribute "package" elem in
        log_debug "Looking up distribution packages for %s" package_name;
        let items = get_entries () in
        try
          let version = StringMap.find package_name items in
          let entry = package_name ^ "-" ^ version in
          let desc_path = packages_dir +/ entry +/ "desc" in
          match get_arch desc_path with
          | None ->
              log_warning "No ARCH in %s" desc_path; map
          | Some arch ->
              let machine = Support.System.canonical_machine arch in
              match try_cleanup_distro_version_warn version package_name with
              | None -> map
              | Some version ->
                  let id = Printf.sprintf "%s:%s:%s:%s" id_prefix package_name version machine in
                  map |> self#add_package_implementation elem props ~is_installed:true ~id ~version ~machine ~extra_attrs:[("quick-test-file", desc_path)];
        with Not_found -> map
    end
end

module Mac = struct
  let macports_db = "/opt/local/var/macports/registry/registry.db"

  (* Note: we currently don't have or need DarwinDistribution, because that uses quick-test-* attributes *)

  class macports_distribution ?(macports_db=macports_db) config slave =
    object
      inherit python_fallback_distribution slave "MacPortsDistribution" [macports_db] as super
      val check_host_python = true

      val! system_paths = ["/opt/local/bin"]

      val distro_name = "MacPorts"
      val id_prefix = "package:macports"
      val cache = new Cache.cache config "macports-status.cache" macports_db 2 ~old_format:true

      method! is_installed elem =
        try check_cache id_prefix elem cache
        with Fallback_to_Python -> super#is_installed elem

      method! match_name name = (name = distro_name || name = "Darwin")
    end

  class darwin_distribution _config slave =
    object
      inherit python_fallback_distribution slave "DarwinDistribution" []
      val check_host_python = true
      val distro_name = "Darwin"
      val id_prefix = "package:darwin"
    end
end

module Win = struct
  class windows_distribution _config slave =
    object
      inherit python_fallback_distribution slave "WindowsDistribution" []
      val check_host_python = false (* (0install's bundled Python may not be generally usable) *)

      val! system_paths = []

      val distro_name = "Windows"
      val id_prefix = "package:windows"

      method! private get_package_impls map (elem, _props) =
        let package_name = ZI.get_attribute "package" elem in
        match package_name with
        | "openjdk-6-jre" | "openjdk-6-jdk"
        | "openjdk-7-jre" | "openjdk-7-jdk"
        | "netfx" | "netfx-client" ->
            Qdom.log_elem Support.Logging.Info "FIXME: Windows: can't check for package '%s':" package_name elem;
            raise Fallback_to_Python
        | _ -> map

        (* No PackageKit support on Windows *)
      method! check_for_candidates _feed = Lwt.return ()
    end

  let cygwin_log = "/var/log/setup.log"

  class cygwin_distribution config slave =
    object
      inherit python_fallback_distribution slave "CygwinDistribution" ["/var/log/setup.log"] as super
      val check_host_python = false (* (0install's bundled Python may not be generally usable) *)

      val distro_name = "Cygwin"
      val id_prefix = "package:cygwin"
      val cache = new Cache.cache config "cygcheck-status.cache" cygwin_log 2 ~old_format:true

      method! is_installed elem =
        try check_cache id_prefix elem cache
        with Fallback_to_Python -> super#is_installed elem
    end
end

module Ports = struct
  let pkg_db = "/var/db/pkg"

  class ports_distribution ?(pkgdir=pkg_db) _config slave =
    object
      inherit python_fallback_distribution slave "PortsDistribution" [pkgdir]
      val check_host_python = true
      val id_prefix = "package:ports"
      val distro_name = "Ports"
    end
end

module Gentoo = struct
  class gentoo_distribution ?(pkgdir=Ports.pkg_db) _config slave =
    object
      inherit python_fallback_distribution slave "GentooDistribution" [pkgdir]
      val check_host_python = false
      val distro_name = "Gentoo"
      val id_prefix = "package:gentoo"
    end
end

module Slackware = struct
  let slack_db = "/var/log/packages"

  class slack_distribution ?(packages_dir=slack_db) _config slave =
    object
      inherit python_fallback_distribution slave "SlackDistribution" [packages_dir]
      val check_host_python = false
      val distro_name = "Slack"
      val id_prefix = "package:slack"
    end
end

let get_host_distribution config (slave:Python.slave) : distribution =
  let x = Sys.file_exists in

  match Sys.os_type with
  | "Unix" ->
      let is_debian =
        match config.system#stat Debian.dpkg_db_status with
        | Some info when info.Unix.st_size > 0 -> true
        | _ -> false in

      if is_debian then
        new Debian.debian_distribution config slave
      else if x ArchLinux.arch_db then
        new ArchLinux.arch_distribution config slave
      else if x RPM.rpm_db_packages then
        new RPM.rpm_distribution config slave
      else if x Mac.macports_db then
        new Mac.macports_distribution config slave
      else if x Ports.pkg_db then (
        if config.system#platform.Platform.os = "Linux" then
          new Gentoo.gentoo_distribution config slave
        else
          new Ports.ports_distribution config slave
      ) else if x Slackware.slack_db then
        new Slackware.slack_distribution config slave
      else if config.system#platform.Platform.os = "Darwin" then
        new Mac.darwin_distribution config slave
      else
        new generic_distribution slave
  | "Win32" -> new Win.windows_distribution config slave
  | "Cygwin" -> new Win.cygwin_distribution config slave
  | _ ->
      new generic_distribution slave

(** Check whether this <selection> is still valid. If the quick-test-* attributes are present, use
    them to check. Otherwise, call the appropriate method on [config.distro]. *)
let is_installed config (distro:distribution) elem =
  match ZI.get_attribute_opt "quick-test-file" elem with
  | None -> distro#is_installed elem
  | Some file ->
      match config.system#stat file with
      | None -> false
      | Some info ->
          match ZI.get_attribute_opt "quick-test-mtime" elem with
          | None -> true      (* quick-test-file exists and we don't care about the time *)
          | Some required_mtime -> (Int64.of_float info.Unix.st_mtime) = Int64.of_string required_mtime

(** Get the native implementations (installed or candidates for installation), based on the <package-implementation> elements
    in [feed]. Returns [None] if there were no matching elements (which means that we didn't even check the distribution). *)
let get_package_impls (distro : distribution) feed =
  distro#get_all_package_impls feed

let install_distro_packages (distro:distribution) (ui:Ui.ui_handler) impls : [ `ok | `cancel ] Lwt.t =
  let groups = ref StringMap.empty in
  impls |> List.iter (fun impl ->
    match impl.Feed.impl_type with
    | Feed.PackageImpl {Feed.retrieval_method = rm; _} ->
        let rm = rm |? lazy (raise_safe "Missing retrieval method for package '%s'" (Feed.get_attr_ex FeedAttr.id impl)) in
        let (typ, _info) = rm.Feed.distro_install_info in
        let items = try StringMap.find typ !groups with Not_found -> [] in
        groups := StringMap.add typ ((impl, rm) :: items) !groups
    | _ -> raise_safe "BUG: not a PackageImpl! %s" (Feed.get_attr_ex FeedAttr.id impl)
  );

  let rec loop = function
    | [] -> Lwt.return `ok
    | (typ, items) :: groups ->
        match_lwt distro#install_distro_packages ui typ items with
        | `ok -> loop groups
        | `cancel -> Lwt.return `cancel in
  !groups |> StringMap.bindings |> loop
