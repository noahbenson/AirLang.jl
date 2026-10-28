# AirLang Implementation Stress-Test Suite

This document outlines a curated suite of 25 benchmarks and problems designed to stress-test an implementation of Air, covering core collections, pattern matching, the RETE deductive logic engine, STM transactions, and advanced metaprogramming.

## Tier 1: Core Collections, Immutability, and Data Manipulation
*Testing: Persistent data structures, `with`, `wout`, and structural transformations.*

1. **Word Frequency Counter:** Parse a text block into tokens, build a keyword-indexed map of counts, and update entries using `with`.
2. **Nested Map Patching:** Write a function to deeply update nested configuration maps using structured paths and `with`.
3. **Sequence Rotation & Splice:** Insert, delete, and rearrange elements in a vector at arbitrary indices using `with` and `wout`.
4. **Run-Length Encoding (RLE):** Compress and decompress sequential lists using pattern matching and vector collection methods.
5. **JSON-to-Air Map Normalization:** Convert raw nested key-value data structures into standardized Air keyword-headed maps.

## Tier 2: Pattern Matching, Guards, and Term-Rewriting (`on`)
*Testing: Lexical reduction rules, guards (`\ type?`), and evaluation fixed points.*

6. **Symbolic Algebraic Simplifier:** Implement rules using `on` to simplify arithmetic expressions (e.g., `(+ ?x 0) -> ?x`, `(* ?x 1) -> ?x`, `(* ?x 0) -> 0`).
7. **Symbolic Differentiation Engine:** Write recursive rewrite rules to compute the derivative of polynomial and trigonometric expressions with respect to a variable.
8. **Pattern Guards & Input Validation:** Implement a function that validates incoming arguments using type guards (`\ symbol?`, `\ integer?`) and raises structured errors `(raise :arg-type ...)` when invalid.
9. **Depth-Controlled Lowering (`lower`):** Write a transformation using `lower` to selectively push held forms down to depth $k$ or leaf sinks (`-1`) across complex ASTs.
10. **Tail-Call Optimized Factorial & Fibonacci:** Test recursive evaluation, base-case pattern ordering, and fixed-point execution limits.
11. **Structural Schema Validator:** Write a set of pattern-matching rules that validate an arbitrary map structure against a declarative data schema.

## Tier 3: Deductive Logic and the RETE Engine (`logic-set`)
*Testing: Fact assertion, rule firing, transitive closures, and determinism.*

12. **Family Tree Transitive Closure:** Assert parent/child facts into a `logic-set` and derive `ancestor` and `descendant` relationships.
13. **Graph Shortest Path:** Use deductive rules to propagate edge weights and find the shortest path between nodes in a directed graph.
14. **Expert Diagnostic System:** Build a rule-based troubleshooting guide (e.g., for software errors or hardware diagnostics) where facts trigger cascading conclusions.
15. **Constraint Satisfaction (Sudoku or N-Queens):** Use production rules to prune invalid states and solve constraint satisfaction puzzles.
16. **State Machine / Workflow Engine:** Manage entity lifecycles (`Pending` $\rightarrow$ `Running` $\rightarrow$ `Complete`) via RETE rules reacting to state facts.
17. **Package Dependency Resolver:** Resolve version constraints across a dependency graph using deductive logic rules.

## Tier 4: Error Handling, STM Transactions, and Persistence
*Testing: `do`/`except`/`finally` (with `catch=`/`throw` and
`handle`/`notify`), transactional rollbacks, and recovery.*

18. **Robust Bank Transfer:** Execute a multi-account balance transfer inside an STM transaction; verify that unhandled errors trigger automatic rollbacks while caught validation errors preserve account state.
19. **IO Retry with Backoff:** Write a function that executes a flaky operation, handles specific `(raise :io ...)` errors, logs the failure, and retries up to $N$ times.
20. **Persistent Event Sourcing Log:** Model an append-only log of transactional state changes, testing replay and snapshotting mechanisms.
21. **Concurrent Multi-Threaded Counter:** Spawn multiple threads concurrently updating shared persistent state via `Air.jl` to stress-test transaction isolation.

## Tier 5: Advanced Metaprogramming and Grand Challenges
*Testing: Code-as-data, interpreters, and full-system integration.*

22. **A Tiny Sub-Language Interpreter:** Write an interpreter in Air that evaluates a subset of Air expressions (bindings, arithmetic, and conditionals) using environment maps.
23. **SQL AST Generator:** Build a macro/rewriting DSL that translates Air database query forms into structured PostgreSQL syntax trees.
24. **Conway’s Game of Life:** Implement a 2D grid simulation combining vector indexing, pattern matching for neighbor counting, and rule-based generation updates.
25. **Mini-Prolog Engine:** Implement a backward-chaining logical query engine (unification and resolution) built entirely on top of Air's term-matching primitives.