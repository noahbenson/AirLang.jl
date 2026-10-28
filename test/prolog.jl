@testset "mini-prolog" begin
    # A small resolution engine written entirely in air. It exercises `hold=`
    # parameters, dynamic map keys, quoted terms, `loop`/`recur`, and the
    # `symbol` builtin (runtime variable freshening).
    PROLOG = raw"""
# ---- Mini-Prolog: unification ------------------------------------------------

(def (deref ?t ?s) hold=(t)
  (if (and (wildcard? t) (haskey s (keyword (name t))))
      (let (v=(get s (keyword (name t))))
        (deref v s))
      t))

(def (bind-var ?v ?t ?s)
  (join s ~(keyword (name v))=t))

(def (term-equal ?a ?b) hold=(a b)
  (if (seq? a)
      (if (seq? b)
          (if (== (count a) (count b))
              (loop (i 1)
                (if (i > (count a))
                    true
                    (let (ai=(get a i) bi=(get b i))
                      (if (term-equal ai bi)
                          (recur (i + 1))
                          false))))
              false)
          false)
      (if (seq? b) false (eq? (unhold a) (unhold b)))))

(def (unify-list ?xs ?ys ?i ?s) hold=(xs ys)
  (if (i > (count xs))
      s
      (let (xi=(get xs i) yi=(get ys i))
        (let (s2=(unify xi yi s))
  (if (eq? s2 :fail)
              :fail
              (unify-list xs ys (i + 1) s2))))))

(def (unify ?a ?b ?s) hold=(a b)
  (let (da=(deref a s) db=(deref b s))
    (if (and (wildcard? da) (wildcard? db) (term-equal da db))
        s
        (if (wildcard? da)
            (bind-var da db s)
            (if (wildcard? db)
                (bind-var db da s)
                (if (and (seq? da) (seq? db))
                    (if (== (count da) (count db))
                        (unify-list da db 1 s)
                        :fail)
                    (if (term-equal da db) s :fail)))))))

# ---- Mini-Prolog: resolution -------------------------------------------------

(def (rename-term ?t ?tag) hold=(t)
  (if (wildcard? t)
      (symbol (str "?" (name t) tag))
      (if (seq? t)
          (map (?e -> (rename-term e tag)) t)
          t)))

(def (push-goals ?q ?b)
  (loop (i (- (count b) 1) acc q)
    (if (i < 2)
        acc
        (recur (i - 1) (push acc (get b i))))))

(def (vars ?t ?acc) hold=(t)
  (if (wildcard? t)
      (if (member? t acc) acc (push acc t))
      (if (seq? t)
          (reduce ((?acc ?e) -> (vars e acc)) acc t)
          acc)))

(def (project ?vset ?s)
  (reduce ((?acc ?v) -> (join acc ~(keyword (name v))=(deref v s)))
          ()
          (drop-first 2 vset)))

(def (sol-count ?ss) (if (symbol? ss) 0 (- (count ss) 1)))
(def (sol-get ?ss ?i) (get ss (i + 1)))
(def (sol-add ?ss ?s) (if (symbol? ss) (sols s) (push ss s)))
(def (sol-merge ?a ?b)
  (loop (i 1 acc a)
    (if (i > (sol-count b))
        acc
        (recur (i + 1) (sol-add acc (sol-get b i))))))

(def (solve-clauses ?i ?acc ?g ?q ?db ?tag ?s ?vset)
  (loop (i i acc acc)
    (if (i > (count db))
        acc
        (let (c=(get db i))
          (let (tag2=(str tag "_" i))
  (let (h0=(get c :head))
  (let (b0=(get c :body))
  (let (h=(rename-term h0 tag2))
  (let (b=(rename-term b0 tag2))
  (let (s2=(unify g h s))
  (recur (i + 1)
                             (if (eq? s2 :fail)
                                 acc
                                 (sol-merge acc (solve-q (push-goals q b) db tag2 s2 vset))))))))))))))

(def (solve-q ?q ?db ?tag ?s ?vset)
  (if (== (count q) 2)
      (sol-add sols (project vset s))
      (let (n=(count q))
        (let (g=(get q n))
  (let (q2=(wout q n))
  (solve-clauses 2 sols g q2 db tag s vset))))))

(def (solve ?goal ?db) hold=(goal)
  (solve-q (goals :done goal) db "" () (vars goal (vs :done))))
"""

    CLAUSES = """(clauses
        (head=(parent :abe :bob) body=(goals :done))
        (head=(parent :bob :carl) body=(goals :done))
        (head=(ancestor ?x ?y) body=(goals (parent ?x ?y) :done))
        (head=(ancestor ?x ?y) body=(goals (parent ?x ?z) (ancestor ?z ?y) :done)))"""

    function solve(query::String)
        env = default_env()
        for f in read_all_air(PROLOG)
            air_eval(env, f)
        end
        return air_string(air_eval(env, read_air("(let (db=$CLAUSES) (solve $query db))")))
    end

    @test solve("(parent :abe ?who)") == "(sols (who=:bob))"
    @test solve("(parent :carl ?who)") == "sols"
    @test solve("(ancestor :bob ?who)") == "(sols (who=:carl))"
    @test solve("(ancestor :abe ?who)") == "(sols (who=:bob) (who=:carl))"
    @test solve("(ancestor ?a ?b)") ==
        "(sols (a=:abe b=:bob) (a=:bob b=:carl) (a=:abe b=:carl))"
end
