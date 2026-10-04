{ pkgs, lib }:
{
  selection,
  postCheckout ? "",
  ...
}@args:
let
  selected = import ./selection.nix { inherit lib; } selection;
  checkout = ''
    (cd "$out" && GIT_NO_LAZY_FETCH=1 bash ${./check-selection.sh} ${selected.checked})
    ${postCheckout}
  '';
  fetcherArgs =
    builtins.removeAttrs args [
      "selection"
      "postCheckout"
    ]
    // {
      inherit (selected) sparseCheckout;
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
