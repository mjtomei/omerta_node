# Formal Specification of OMT (Omerta Transaction Language)

This document presents a formal specification of the Omerta Transaction Language (OMT) in the style of academic programming language papers. We define the abstract syntax via BNF grammar, static semantics via well-formedness judgments, and dynamic semantics via a labeled transition system. We then discuss the relationship to multiparty session types and identify directions for future formal development.

---

## B.1 Abstract Syntax

We present the abstract syntax of OMT using BNF notation. Metavariables are written in italics; terminal symbols in **bold** or `monospace`.

### Syntactic Categories

| Metavariable | Domain |
|--------------|--------|
| *x*, *y*, *z* | Identifiers |
| *n* | Integer literals |
| *s* | String literals |
| *T* | Transaction definitions |
| *A* | Actor definitions |
| *S*, *S'* | State names |
| *M* | Message types |
| *B* | Block types |
| Type | Types |
| *e* | Expressions |
| *a* | Actions |

### Transaction Structure

```
T ::= transaction n s1 s2 D*            (transaction definition)

D ::= imports x                         (import declaration)
    | parameters ( P* )                 (parameter block)
    | enum x s? ( C* )                  (enumeration)
    | block x by [ R* ] ( F* )          (block type)
    | message x from R to [ R* ] Sig? ( F* )  (message type)
    | function x ( Param* ) -> Type ( Body ) (function)
    | actor x s ( ActorBody )           (actor definition)

P ::= x = n Unit? s?                    (parameter)
C ::= x                                 (enum case)
F ::= x Type                            (field declaration)
R ::= x                                 (role name)
Sig ::= signed                          (signature requirement)
```

### Actor Structure

```
ActorBody ::= store ( F* ) Trigger* State* Trans*

Trigger ::= trigger x ( Param* ) in [ S* ] s?

State ::= state S Mod* s?
Mod   ::= initial | terminal

Trans ::= S -> S' Event Guard? ( a* ) ElseBranch?

Event ::= on x                          (message or trigger)
        | on timeout ( x )              (timeout)
        | auto                          (automatic)

Guard ::= when e

ElseBranch ::= else -> S' ( a* )
```

### Types

```
Type ::= uint | int | bool | string     (primitive types)
       | hash | bytes | signature       (cryptographic types)
       | peer_id | timestamp            (protocol types)
       | list < Type >                  (list type)
       | map < Type , Type >            (map type)
       | dict                           (dictionary type)
       | x                              (named type / enum)
```

### Expressions

```
e ::= n | s | true | false | null       (literals)
    | x                                 (variable)
    | e.x                               (field access)
    | e [ e ]                           (index access)
    | e BinOp e                         (binary operation)
    | NOT e                             (negation)
    | IF e THEN e ELSE e                (conditional)
    | f ( e* )                          (function call)
    | x => e                            (lambda)
    | { F* }                            (record literal)

BinOp ::= + | - | * | /                 (arithmetic)
        | == | != | < | > | <= | >=     (comparison)
        | AND | OR                      (logical)
```

### Actions

```
a ::= store x*                          (store from message)
    | STORE ( x , e )                   (store computed)
    | x = e                             (assign)
    | SEND ( e , M )                    (send message)
    | BROADCAST ( e , M )               (broadcast)
    | APPEND ( x , e )                  (append to list/chain)
```

---

## B.2 Well-Formedness Judgments (Static Semantics)

We define well-formedness as a collection of judgments that must hold for a transaction definition to be valid. These judgments are analogous to typing rules in traditional type systems, but verify structural properties rather than expression types.

### Environments

Let Γ denote a *transaction environment* containing:

- Γ.params : x → (n, unit, desc)  — parameter definitions
- Γ.enums : x → C*  — enumeration cases
- Γ.messages : M → (from, to, fields)  — message schemas
- Γ.blocks : B → (roles, fields)  — block schemas
- Γ.functions : f → (params, return, body)  — function definitions
- Γ.actors : A → ActorEnv  — actor environments

Let Δ denote an *actor environment* containing:

- Δ.store : x → Type  — store fields
- Δ.states : S → (initial?, terminal?)  — state declarations
- Δ.triggers : x → (params, valid_states)  — trigger declarations

### Transaction Well-Formedness

A transaction is well-formed if all its declarations are well-formed in the transaction environment.

### Actor Well-Formedness

An actor is well-formed if:
1. There is exactly one initial state
2. There is at least one terminal state
3. All states are reachable from the initial state
4. All transitions are well-formed

### State Reachability

The reachability predicate is defined as the reflexive-transitive closure of the transition relation.

---

## B.3 Operational Semantics (Labeled Transition System)

We define the dynamic semantics of OMT actors as a labeled transition system (LTS). This captures how actors execute in response to events.

### Actor Configurations

An actor configuration is a triple ⟨A, S, σ⟩ where:
- *A* is the actor definition
- *S* is the current state
- σ : *x* → *v* is the store (mapping identifiers to values)

### Labels

Transitions are labeled with events:

```
Label ::= tau                           (internal/auto)
        | ?M(v*)                         (receive message M with values)
        | !M(v*)@p                       (send message M to peer p)
        | !M(v*)@P                       (broadcast M to peer set P)
        | timeout(t)                     (timeout after t)
        | trigger(x, v*)                 (external trigger with args)
```

### Transition Rules

**Automatic Transition**: Auto transitions fire when their guard evaluates to true.

**Message Reception**: Message events bind the message to the store, evaluate the guard, and execute actions.

**Trigger Activation**: Triggers bind parameters and execute when the actor is in a valid state.

**Timeout**: Timeout events fire after the specified duration.

**Guarded Else Branch**: When the primary guard fails, the else branch executes.

### Action Evaluation

Actions are evaluated sequentially, threading the store. Send and broadcast actions produce observable effects but do not modify the local store.

---

## B.4 Concurrent Composition

A transaction execution consists of multiple actors running concurrently. We model this as a *parallel composition* of actor configurations with a shared message queue.

### System Configuration

A system configuration is a tuple ⟨C₁, …, Cₙ, Q⟩ where:
- Each Cᵢ = ⟨Aᵢ, Sᵢ, σᵢ⟩ is an actor configuration
- *Q* is a multiset of pending messages

### Composition Rules

**Internal Step**: An actor takes an internal (tau) transition.

**Message Send**: An actor sends a message, adding it to the queue.

**Message Receive**: An actor receives a message from the queue.

---

## B.5 Relationship to Multiparty Session Types

OMT bears strong structural similarity to *multiparty session types* (MPST) [Honda et al. 2008, 2016]. We identify the correspondence and discuss how MPST theory could be applied.

### Correspondence

| MPST Concept | OMT Equivalent |
|--------------|----------------|
| Global type | Transaction definition |
| Local type | Actor definition |
| Role | Actor role (Consumer, Provider, Witness) |
| Message type | `message` declaration |
| Choice | Guarded transitions from same state |
| Recursion | Cycles in state machine |
| End | Terminal state |

### Global Type View

An OMT transaction can be viewed as a *global type* specifying the interaction pattern:

```
Escrow = Consumer -> Provider : LOCK_INTENT .
         Provider -> Consumer : WITNESS_SELECTION_COMMITMENT .
         Consumer -> Witness* : WITNESS_REQUEST .
         Witness <-> Witness : WITNESS_PRELIMINARY .
         Witness <-> Witness : WITNESS_FINAL_VOTE .
         Witness -> Consumer : LOCK_RESULT_FOR_SIGNATURE .
         Consumer -> Witness* : CONSUMER_SIGNED_LOCK .
         end
```

### Potential for Session Type Verification

The MPST framework provides several verification guarantees that could be adapted to OMT:

1. **Communication Safety**: Well-typed sessions do not have message type mismatches.
2. **Protocol Conformance**: Each actor follows the prescribed interaction pattern.
3. **Deadlock Freedom**: Well-formed global types project to local types that cannot deadlock.
4. **Progress**: If the system can make a step, it will.

**Key Difference**: MPST typically uses *projection* to derive local types from a global type. OMT instead specifies local types (actors) directly, with the global protocol emerging from their composition. This is closer to the *bottom-up* approach of choreographic programming [Montesi 2013] or the *communicating automata* framework [Brand & Zafiropulo 1983].

---

## B.6 Related Formalisms

OMT's design draws on several formal traditions:

**Process Calculi** [Milner 1980, 1999]: The concurrent composition of actors follows CCS/pi-calculus style. Our LTS semantics uses standard structural operational semantics (SOS) [Plotkin 1981].

**Communicating Finite State Machines** [Brand & Zafiropulo 1983]: Each actor is essentially a CFSM. The extensive theory of CFSMs (decidability results, verification algorithms) may apply.

**Scribble** [Yoshida et al. 2014]: A protocol description language based on MPST. Scribble's syntax influenced OMT's message declarations. The Scribble toolchain generates endpoint APIs from global protocols—a similar approach could generate OMT actor skeletons.

**Promela/SPIN** [Holzmann 1997]: A verification-oriented protocol language. SPIN's model checking approach (state space exploration, LTL verification) could be adapted for OMT transaction verification.

**TLA+** [Lamport 2002]: A specification language based on temporal logic. TLA+'s approach to specifying state machines with temporal properties provides a model for formal verification of OMT transactions.

---

## B.7 Future Work

We identify several directions for formal development:

### Type System Extensions

1. **Refinement Types**: Extend field types with predicates (e.g., `amount : uint{v > 0}`) to capture value constraints. This would enable static verification of guards.

2. **Linear Types**: Track message consumption linearly to ensure each message is processed exactly once. This connects to session type linearity.

3. **Dependent Types**: Allow types to depend on values (e.g., `list<peer_id>{length = WITNESS_COUNT}`). This would strengthen static guarantees.

### Verification

1. **Model Checking**: Translate OMT transactions to Promela or TLA+ for automatic verification of safety and liveness properties.

2. **Session Type Checking**: Implement projection from a global protocol specification to verify that actor definitions conform.

3. **Deadlock Analysis**: Develop static analysis to detect potential deadlocks in actor compositions.

### Tooling

1. **Formal Semantics in Coq/Agda**: Mechanize the semantics for machine-checked proofs of meta-theoretic properties (type safety, progress, preservation).

2. **Test Generation**: Use the formal semantics to generate test cases that cover all transition paths.

3. **Runtime Monitoring**: Generate runtime monitors from OMT specifications to detect protocol violations during execution.

---

## References

[Brand & Zafiropulo 1983] D. Brand and P. Zafiropulo. "On Communicating Finite-State Machines." *Journal of the ACM*, 30(2):323-342, 1983. https://doi.org/10.1145/322374.322380

[Holzmann 1997] G. J. Holzmann. "The Model Checker SPIN." *IEEE Transactions on Software Engineering*, 23(5):279-295, 1997. https://spinroot.com/spin/Doc/ieee97.pdf

[Honda et al. 2008] K. Honda, N. Yoshida, and M. Carbone. "Multiparty Asynchronous Session Types." *POPL 2008*, pages 273-284. https://doi.org/10.1145/1328438.1328472

[Honda et al. 2016] K. Honda, N. Yoshida, and M. Carbone. "Multiparty Asynchronous Session Types." *Journal of the ACM*, 63(1):1-67, 2016. https://doi.org/10.1145/2827695

[Lamport 2002] L. Lamport. *Specifying Systems: The TLA+ Language and Tools for Hardware and Software Engineers*. Addison-Wesley, 2002. https://lamport.azurewebsites.net/tla/book.html

[Milner 1980] R. Milner. *A Calculus of Communicating Systems*. Springer-Verlag, LNCS 92, 1980. https://doi.org/10.1007/3-540-10235-3

[Milner 1999] R. Milner. *Communicating and Mobile Systems: The Pi-Calculus*. Cambridge University Press, 1999. https://doi.org/10.1017/CBO9781139166874

[Montesi 2013] F. Montesi. "Choreographic Programming." Ph.D. thesis, IT University of Copenhagen, 2013. https://www.fabriziomontesi.com/files/choreographic-programming.pdf

[Plotkin 1981] G. D. Plotkin. "A Structural Approach to Operational Semantics." Technical Report DAIMI FN-19, Aarhus University, 1981. https://homepages.inf.ed.ac.uk/gdp/publications/sos_jlap.pdf

[Yoshida et al. 2014] N. Yoshida, R. Hu, R. Neykova, and N. Ng. "The Scribble Protocol Language." *TGC 2013*, LNCS 8358, pages 22-41, 2014. https://doi.org/10.1007/978-3-642-54262-1_3
