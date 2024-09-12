# Copyright 2024 Adobe. All rights reserved.
# This file is licensed to you under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License. You may obtain a copy
# of the License at http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software distributed under
# the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
# OF ANY KIND, either express or implied. See the License for the specific language
# governing permissions and limitations under the License.

defmodule Styler.Style.ModuleDirectives do
  @moduledoc """
  Styles up module directives!

  This Style will expand multi-aliases/requires/imports/use and sort the directive within its groups (except `use`s, which cannot be sorted)
  It also adds a blank line after each directive group.

  ## Credo rules

  Rewrites for the following Credo rules:

    * `Credo.Check.Consistency.MultiAliasImportRequireUse` (force expansion)
    * `Credo.Check.Readability.AliasOrder` (we sort `__MODULE__`, which credo doesn't)
    * `Credo.Check.Readability.ModuleDoc` (adds `@moduledoc false` if missing. includes `*.exs` files)
    * `Credo.Check.Readability.MultiAlias`
    * `Credo.Check.Readability.StrictModuleLayout` (see section below for details)
    * `Credo.Check.Readability.UnnecessaryAliasExpansion`
    * `Credo.Check.Design.AliasUsage`

  ### Strict Layout

  Modules directives are sorted into the following order:

    * `@shortdoc`
    * `@moduledoc`
    * `@behaviour`
    * `use`
    * `import`
    * `alias`
    * `require`
    * everything else (unchanged)
  """
  @behaviour Styler.Style

  alias Styler.AliasEnv
  alias Styler.Style
  alias Styler.Zipper

  @directives ~w(alias import require use)a
  @attr_directives ~w(moduledoc shortdoc behaviour)a
  @defstruct ~w(schema embedded_schema defstruct)a

  @moduledoc_false {:@, [line: nil], [{:moduledoc, [line: nil], [{:__block__, [line: nil], [false]}]}]}

  def run({{:defmodule, _, children}, _} = zipper, ctx) do
    [name, [{{:__block__, do_meta, [:do]}, _body}]] = children

    if do_meta[:format] == :keyword do
      {:skip, zipper, ctx}
    else
      moduledoc = moduledoc(name)
      # Move the zipper's focus to the module's body
      body_zipper = zipper |> Zipper.down() |> Zipper.right() |> Zipper.down() |> Zipper.down() |> Zipper.right()

      case Zipper.node(body_zipper) do
        # an empty body - replace it with a moduledoc and call it a day ¯\_(ツ)_/¯
        {:__block__, _, []} ->
          zipper = if moduledoc, do: Zipper.replace(body_zipper, moduledoc), else: body_zipper
          {:skip, zipper, ctx}

        # we want only-child literal block to be handled in the only-child catch-all. it means someone did a weird
        # (that would be a literal, so best case someone wrote a string and forgot to put `@moduledoc` before it)
        {:__block__, _, [_, _ | _]} ->
          {:skip, organize_directives(body_zipper, moduledoc), ctx}

        # a module whose only child is a moduledoc. nothing to do here!
        # seems weird at first blush but lots of projects/libraries do this with their root namespace module
        {:@, _, [{:moduledoc, _, _}]} ->
          {:skip, zipper, ctx}

        # There's only one child, and it's not a moduledoc. Conditionally add a moduledoc, then style the only_child
        only_child ->
          if moduledoc do
            zipper =
              body_zipper
              |> Zipper.replace({:__block__, [], [moduledoc, only_child]})
              |> organize_directives()

            {:skip, zipper, ctx}
          else
            run(body_zipper, ctx)
          end
      end
    end
  end

  # Style directives inside of snippets or function defs.
  def run({{directive, _, children}, _} = zipper, ctx) when directive in @directives and is_list(children) do
    # Need to be careful that we aren't getting false positives on variables or fns like `def import(foo)` or `alias = 1`
    case Style.ensure_block_parent(zipper) do
      {:ok, zipper} -> {:skip, zipper |> Zipper.up() |> organize_directives(), ctx}
      # not actually a directive! carry on.
      :error -> {:cont, zipper, ctx}
    end
  end

  # puts `@derive` before `defstruct` etc, fixing compiler warnings
  def run({{:@, _, [{:derive, _, _}]}, _} = zipper, ctx) do
    case Style.ensure_block_parent(zipper) do
      {:ok, {derive, %{l: left_siblings} = z_meta}} ->
        previous_defstruct =
          left_siblings
          |> Stream.with_index()
          |> Enum.find_value(fn
            {{struct_def, meta, _}, index} when struct_def in @defstruct -> {meta[:line], index}
            _ -> nil
          end)

        if previous_defstruct do
          {defstruct_line, defstruct_index} = previous_defstruct
          derive = Style.set_line(derive, defstruct_line - 1)
          left_siblings = List.insert_at(left_siblings, defstruct_index + 1, derive)
          {:skip, Zipper.remove({derive, %{z_meta | l: left_siblings}}), ctx}
        else
          {:cont, zipper, ctx}
        end

      :error ->
        {:cont, zipper, ctx}
    end
  end

  def run(zipper, ctx), do: {:cont, zipper, ctx}

  defp moduledoc({:__aliases__, m, aliases}) do
    name = aliases |> List.last() |> to_string()
    # module names ending with these suffixes will not have a default moduledoc appended
    unless String.ends_with?(name, ~w(Test Mixfile MixProject Controller Endpoint Repo Router Socket View HTML JSON)) do
      Style.set_line(@moduledoc_false, m[:line] + 1)
    end
  end

  # a dynamic module name, like `defmodule my_variable do ... end`
  defp moduledoc(_), do: nil

  @acc %{
    shortdoc: [],
    moduledoc: [],
    behaviour: [],
    use: [],
    import: [],
    alias: [],
    require: [],
    nondirectives: [],
    dealiases: %{},
    attrs: MapSet.new(),
    attr_lifts: []
  }

  defp lift_module_attrs({node, _, _} = ast, %{attrs: attrs} = acc) do
    if Enum.empty?(attrs) do
      {ast, acc}
    else
      use? = node == :use

      Macro.prewalk(ast, acc, fn
        {:@, m, [{attr, _, _} = var]} = ast, acc ->
          if attr in attrs do
            replacement =
              if use?,
                do: {:unquote, [closing: [line: m[:line]], line: m[:line]], [var]},
                else: var

            {replacement, %{acc | attr_lifts: [attr | acc.attr_lifts]}}
          else
            {ast, acc}
          end

        ast, acc ->
          {ast, acc}
      end)
    end
  end

  defp organize_directives(parent, moduledoc \\ nil) do
    acc =
      parent
      |> Zipper.children()
      |> Enum.reduce(@acc, fn
        {:@, _, [{attr_directive, _, _}]} = ast, acc when attr_directive in @attr_directives ->
          # attr_directives are moved above aliases, so we need to dealias them
          {ast, acc} = acc.dealiases |> AliasEnv.expand(ast) |> lift_module_attrs(acc)
          %{acc | attr_directive => [ast | acc[attr_directive]]}

        {:@, _, [{attr, _, _}]} = ast, acc ->
          %{acc | nondirectives: [ast | acc.nondirectives], attrs: MapSet.put(acc.attrs, attr)}

        {directive, _, _} = ast, acc when directive in @directives ->
          {ast, acc} = lift_module_attrs(ast, acc)
          ast = expand(ast)
          # import and used get hoisted above aliases, so need to dealias
          ast = if directive in ~w(import use)a, do: AliasEnv.expand(acc.dealiases, ast), else: ast
          dealiases = if directive == :alias, do: AliasEnv.define(acc.dealiases, ast), else: acc.dealiases

          # the reverse accounts for `expand` putting things in reading order, whereas we're accumulating in reverse
          %{acc | directive => Enum.reverse(ast, acc[directive]), dealiases: dealiases}

        ast, acc ->
          %{acc | nondirectives: [ast | acc.nondirectives]}
      end)
      # Reversing once we're done accumulating since `reduce`ing into list accs means you're reversed!
      |> Map.new(fn
        {:moduledoc, []} -> {:moduledoc, List.wrap(moduledoc)}
        {:use, uses} -> {:use, uses |> Enum.reverse() |> Style.reset_newlines()}
        {directive, to_sort} when directive in ~w(behaviour import alias require)a -> {directive, sort(to_sort)}
        {:dealiases, d} -> {:dealiases, d}
        {k, v} -> {k, Enum.reverse(v)}
      end)

    # Not happy with it, but this does the work to move module attribute assignments above the module or quote or whatever
    # Given that it'll only be run once and not again, i'm okay with it being inefficient
    {acc, parent} =
      if Enum.any?(acc.attr_lifts) do
        lifts = acc.attr_lifts

        nondirectives =
          Enum.map(acc.nondirectives, fn
            {:@, m, [{attr, am, _}]} = ast -> if attr in lifts, do: {:@, m, [{attr, am, [{attr, am, nil}]}]}, else: ast
            ast -> ast
          end)

        assignments =
          Enum.flat_map(acc.nondirectives, fn
            {:@, m, [{attr, am, [val]}]} -> if attr in lifts, do: [{:=, m, [{attr, am, nil}, val]}], else: []
            _ -> []
          end)

        {past, _} = parent

        parent =
          parent
          |> Zipper.up()
          |> Style.find_nearest_block()
          |> Zipper.prepend_siblings(assignments)
          |> Zipper.find(&(&1 == past))

        {%{acc | nondirectives: nondirectives}, parent}
      else
        {acc, parent}
      end

    nondirectives = acc.nondirectives

    directives =
      [
        acc.shortdoc,
        acc.moduledoc,
        acc.behaviour,
        acc.use,
        acc.import,
        acc.alias,
        acc.require
      ]
      |> Stream.concat()
      |> Style.fix_line_numbers(List.first(nondirectives))

    # the # of aliases can be decreased during sorting - if there were any, we need to be sure to write the deletion
    if Enum.empty?(directives) do
      Zipper.replace_children(parent, nondirectives)
    else
      # this ensures we continue the traversal _after_ any directives
      parent
      |> Zipper.replace_children(directives)
      |> Zipper.down()
      |> Zipper.rightmost()
      |> Zipper.insert_siblings(nondirectives)
    end
  end

  # Deletes root level aliases ala (`alias Foo` -> ``)
  defp expand({:alias, _, [{:__aliases__, _, [_]}]}), do: []

  # import Foo.{Bar, Baz}
  # =>
  # import Foo.Bar
  # import Foo.Baz
  defp expand({directive, _, [{{:., _, [{:__aliases__, _, module}, :{}]}, _, right}]}) do
    Enum.map(right, fn {_, meta, segments} ->
      {directive, meta, [{:__aliases__, [line: meta[:line]], module ++ segments}]}
    end)
  end

  # alias __MODULE__.{Bar, Baz}
  defp expand({directive, _, [{{:., _, [{:__MODULE__, _, _} = module, :{}]}, _, right}]}) do
    Enum.map(right, fn {_, meta, segments} ->
      {directive, meta, [{:__aliases__, [line: meta[:line]], [module | segments]}]}
    end)
  end

  defp expand(other), do: [other]

  defp sort(directives) do
    # sorting is done with `downcase` to match Credo
    directives
    |> Enum.map(&{&1, &1 |> Macro.to_string() |> String.downcase()})
    |> Enum.uniq_by(&elem(&1, 1))
    |> List.keysort(1)
    |> Enum.map(&elem(&1, 0))
    |> Style.reset_newlines()
  end
end
