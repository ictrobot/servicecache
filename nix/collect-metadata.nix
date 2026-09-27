{ lib }:
items:
let
  merge =
    field: equal:
    lib.zipAttrsWith (
      name: values:
      let
        value = builtins.head values;
      in
      assert lib.assertMsg (lib.all (equal value) values) "Conflicting ${field} entry: ${name}";
      value
    ) (map (item: item.${field} or { }) items);
in
{
  upstreamSources = merge "upstreamSources" (
    a: b: a.tar.outPath == b.tar.outPath && a.metadata == b.metadata
  );
  servicecacheFiles = merge "servicecacheFiles" (a: b: toString a == toString b);
}
