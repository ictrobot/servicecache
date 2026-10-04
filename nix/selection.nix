# Turns a source selection into the Git sparse-checkout patterns that both
# fetchers apply.
#
# scope lists the directories a Git source fetches, such as "llvm/cmake".
# Files at the repository root and directly inside a scoped directory's
# parents come too. Without a scope the whole source is fetched.
#
# exclude lists rules, each with patterns in .gitignore syntax and the reason
# they are unused. A match is left out, a pattern starting with ! keeps what
# it matches, and the last matching pattern decides: "/doc/" then
# "!/doc/build.info" leaves out doc/ except build.info.
{ lib }:
selection:
let
  cleanPath =
    path:
    let
      value = lib.removeSuffix "/" path;
    in
    if
      builtins.match "[A-Za-z0-9._+/-]+" value == null
      || lib.any (part: part == "." || part == ".." || part == "") (lib.splitString "/" value)
    then
      throw "invalid source selection path: ${path}"
    else
      value;
  scope = map cleanPath (selection.scope or [ ]);
  parents =
    path:
    lib.init (
      lib.imap0 (index: _: lib.concatStringsSep "/" (lib.take (index + 1) (lib.splitString "/" path))) (
        lib.splitString "/" path
      )
    );
  scopeParents = lib.unique (lib.concatMap parents scope);
  # A limited scope keeps what Git's cone mode would: the scoped directories,
  # plus the files at the repository root and directly inside their parents.
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
  excluded = lib.concatMap (rule: rule.patterns) (selection.exclude or [ ]);
  # Sparse checkout lists what stays, so every exclusion pattern is negated.
  # The second pattern covers everything below a matched directory, as in a
  # .gitignore: alone, sparse checkout lets an earlier pattern that matches
  # the files themselves override a directory's match.
  negate =
    pattern:
    let
      keeps = lib.hasPrefix "!" pattern;
      body = lib.removeSuffix "/" (lib.removePrefix "!" pattern);
      anchored = if lib.hasInfix "/" body then body else "**/${body}";
    in
    map (matched: if keeps then matched else "!${matched}") [
      (lib.removePrefix "!" pattern)
      "${anchored}/**"
    ];
in
{
  inherit scope;
  reduces = excluded != [ ];
  sparseCheckout = scopePatterns ++ lib.concatMap negate excluded;
  # Patterns that must each match a tracked file.
  checked = builtins.toFile "selection-patterns" (
    lib.concatMapStrings (pattern: "${pattern}\n") (
      map (path: "/${path}/") scope ++ map (lib.removePrefix "!") excluded
    )
  );
}
