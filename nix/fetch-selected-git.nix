{ pkgs, lib }:
{
  selection,
  postCheckout ? "",
  ...
}@args:
let
  clean =
    path:
    let
      value = lib.removeSuffix "/" path;
    in
    if
      builtins.match "[A-Za-z0-9._+/-]+" value == null
      || lib.any (part: part == "." || part == ".." || part == "") (lib.splitString "/" value)
    then
      throw "invalid Git source selection path: ${path}"
    else
      value;
  scope = map clean (selection.scope or [ ]);
  parents =
    path:
    lib.init (
      lib.imap0 (index: _: lib.concatStringsSep "/" (lib.take (index + 1) (lib.splitString "/" path))) (
        lib.splitString "/" path
      )
    );
  scopeParents = lib.unique (lib.concatMap parents scope);
  # A limited scope also keeps files at the repository root and beside its parent directories.
  scopePatterns =
    if scope == [ ] then
      [ "/*" ]
    else
      [
        "/*"
        "!/*/"
      ]
      ++ lib.concatMap (path: [
        "/${path}/*"
        "!/${path}/*/"
      ]) scopeParents
      ++ map (path: "/${path}/**") scope;
  within = path: kept: kept == path || lib.hasPrefix "${path}/" kept;
  exclusions = map (
    rule:
    let
      paths = map clean rule.paths;
      kept = map clean (rule.keep or [ ]);
    in
    if lib.all (keep: lib.any (path: within path keep) paths) kept then
      { inherit paths kept; }
    else
      throw "Git source keep is outside its excluded paths"
  ) (selection.exclude or [ ]);
  excludedPatterns = lib.concatMap (
    rule:
    lib.concatMap (path: [
      "!/${path}"
      "!/${path}/**"
    ]) rule.paths
    ++ lib.concatMap (path: [
      "/${path}"
      "/${path}/**"
    ]) rule.kept
  ) exclusions;
  shellArgs = values: lib.concatMapStringsSep " " lib.escapeShellArg values;
  checkedPaths = lib.unique (
    map (path: "${path}/") scope ++ lib.concatMap (rule: rule.paths ++ rule.kept) exclusions
  );
  sparseCheckout = scopePatterns ++ excludedPatterns;
  checkout = ''
    for path in ${shellArgs checkedPaths}; do
      if ! GIT_NO_LAZY_FETCH=1 git -C "$out" ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1; then
        echo "Git source selection path has no tracked files: $path" >&2
        exit 1
      fi
    done
    ${postCheckout}
  '';
  fetcherArgs =
    builtins.removeAttrs args [
      "selection"
      "postCheckout"
    ]
    // {
      inherit sparseCheckout;
      nonConeMode = true;
      postCheckout = checkout;
      passthru = (args.passthru or { }) // {
        scSelection = selection;
      };
    };
  # Fixed-output paths depend on the name and expected hash, not the recipe,
  # so the name carries a hash of what decides the checkout: the arguments,
  # selection included, the git version and nixpkgs' fetch scripts, the
  # builder that turns the arguments into flags and nix-prefetch-git. None
  # of these depend on the system, so every system evaluates the same path.
  fetch = pkgs.fetchgit fetcherArgs;
  fingerprint = builtins.substring 0 12 (
    builtins.hashString "sha256" (
      builtins.toJSON {
        args = builtins.removeAttrs fetcherArgs [ "passthru" ];
        git = pkgs.gitMinimal.version;
        builder = builtins.readFile (lib.last fetch.drvAttrs.args);
        fetcher = builtins.readFile fetch.fetcher;
      }
    )
  );
in
pkgs.fetchgit (fetcherArgs // { name = "${args.name or "source"}-${fingerprint}"; })
