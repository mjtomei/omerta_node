# Citation Graph Analysis

This document analyzes the citation networks for both:
1. New citations recommended from Review Cycle 3
2. Existing citations [1-41] in the Omerta paper

---

## Part 1: New Recommended Citations (from Review Cycle 3)

### High-Impact Works to Add

| Citation | Citations | Key Finding | PDF Access |
|----------|-----------|-------------|------------|
| Golbeck (2005) TidalTrust dissertation | 1,317 | Personalized trust computation | [Academia.edu](https://www.academia.edu/155626/) |
| Richters & Peixoto (2011) Trust Transitivity | 96 | Absolute trust threshold required | [PMC Open Access](https://pmc.ncbi.nlm.nih.gov/articles/PMC3071725/) |
| Friedman & Resnick (2001) Cheap Pseudonyms | 983 | Whitewashing is fundamental | [Semantic Scholar](https://www.semanticscholar.org/paper/e499685036db797c6694509d2d6a2eaf8b52ed4c) |
| MeritRank (2022) | 24 | Bounds Sybil attacks | [arXiv](https://arxiv.org/abs/2207.09950) |
| Tadelis (2016) Reputation Review | 637 | Grade inflation, feedback bias | [Berkeley PDF](https://faculty.haas.berkeley.edu/stadelis/Annual_Review_Tadelis.pdf) |
| Florian et al. (2022) FBA Analysis | ~50 | Open membership limitations | [arXiv](https://arxiv.org/abs/2002.08101) |
| BarterCast (2009) | ~100 | Transaction-based trust | [ResearchGate](https://www.researchgate.net/publication/228871839) |
| SybilLimit (2008) | ~1,500 | O(log n) Sybil bounds | [NUS PDF](https://www.comp.nus.edu.sg/~yuhf/yuh-sybillimit.pdf) |

### Citation Trees for New Recommendations

#### Golbeck (2005) → TidalTrust Lineage
```
Golbeck (2005) "Computing and applying trust" [1,317 citations]
├── Cites: Advogato trust metric (Levien)
├── Cites: PageRank (Page et al.)
├── Cites: EigenTrust (Kamvar et al.) [already cited as [3]]
│
├── Cited by: SUNNY (Kuter & Golbeck, 2007) [341 citations]
├── Cited by: MoleTrust (Massa & Avesani)
├── Cited by: Trust propagation with learning automata (2017)
└── Cited by: DyTrust dynamic trust (2021)
```

#### Richters & Peixoto (2011) → Trust Transitivity
```
Richters & Peixoto (2011) "Trust Transitivity" [96 citations]
├── Cites: PGP Web of Trust studies
├── Cites: Percolation theory literature
│
├── Cited by: Trust network bias/prestige algorithms (2012)
├── Cited by: Smart metering trust studies
└── Cited by: Modal logic trust analysis
```

#### Friedman & Resnick (2001) → Whitewashing Lineage
```
Friedman & Resnick (2001) "Cheap Pseudonyms" [983 citations]
├── Cites: Game theory cooperation literature
├── Cites: Folk theorem economics
│
├── Cited by: "Free-Riding and Whitewashing in P2P" (Feldman, 2004)
├── Cited by: Blockchain reputation systems (2020s)
├── Cited by: Video game toxicity research (2024)
└── Cited by: Identity economics literature
```

---

## Part 2: Existing Paper Citations [1-41] Analysis

### Citation Impact Summary

| Ref | Paper | Citations | Category |
|-----|-------|-----------|----------|
| [3] | EigenTrust (Kamvar et al., 2003) | **5,813** | Core - Reputation |
| [6] | Douceur Sybil Attack (2002) | **7,567** | Core - Security |
| [7] | Bitcoin (Nakamoto, 2008) | **~30,000** | Core - Blockchain |
| [12] | PBFT (Castro & Liskov, 1999) | **~15,000** | Core - Consensus |
| [21] | FHE (Gentry, 2009) | **~12,000** | Core - Crypto |
| [35] | FIRE (Huynh et al., 2006) | **592** | Trust Model |
| [36] | Subjective Logic (Jøsang, 2016) | **732** | Trust Framework |
| [37] | PowerTrust (Zhou & Hwang, 2007) | **781** | Reputation |
| [38] | Budish Blockchain Limits (2018) | **385** | Economics |

### Deep Analysis of Key Citations

#### [3] EigenTrust - Citation Network
```
EigenTrust (2003) [5,813 citations]
│
├── BUILDS ON:
│   ├── PageRank (Page et al., 1999)
│   ├── P2P reputation concepts
│   └── Distributed hash tables
│
├── KEY CITING WORKS:
│   ├── PeerTrust (Xiong & Liu, 2004) [already cited as [4]]
│   ├── PowerTrust (Zhou & Hwang, 2007) [already cited as [37]]
│   ├── HonestPeer (Kurdi, 2015) - honest peer role in global computation
│   ├── EERP (2018) - smart malicious group detection
│   └── Attack-resilient variants (Fan et al., 2012)
│
└── GAPS IN OUR CITATIONS:
    ├── Personalized EigenTrust (Choi, 2010) - NOT CITED
    ├── TidalTrust (Golbeck, 2005) - NOT CITED
    └── EigenTrust attack analysis - NOT CITED
```

#### [6] Douceur Sybil Attack - Citation Network
```
Douceur (2002) [7,567 citations]
│
├── BUILDS ON:
│   ├── Byzantine fault tolerance literature
│   └── Identity in distributed systems
│
├── KEY CITING WORKS:
│   ├── SybilGuard (Yu et al., 2006) [already cited as [9]]
│   ├── SybilLimit (Yu et al., 2008) - NOT CITED (improved bounds)
│   ├── SybilInfer (Danezis & Mittal, 2009) [already cited as [10]]
│   └── SoK: Evolution of Sybil Defense (Alvisi et al., 2013) - NOT CITED
│
└── GAPS IN OUR CITATIONS:
    ├── SybilLimit - tighter bounds than SybilGuard
    └── Comprehensive SoK survey
```

#### [35] FIRE - Citation Network
```
FIRE (Huynh et al., 2006) [592 citations]
│
├── BUILDS ON:
│   ├── REGRET reputation model
│   ├── Beta reputation system
│   └── Witness-based trust
│
├── KEY CITING WORKS:
│   ├── TRAVOS (Teacy et al., 2006) - probabilistic trust
│   ├── FIRE+ with collusion detection
│   └── Multi-agent trust surveys
│
└── OUR PAPER: Correctly cites FIRE; uses its multi-source concept
```

#### [37] PowerTrust - Citation Network
```
PowerTrust (Zhou & Hwang, 2007) [781 citations]
│
├── BUILDS ON:
│   ├── EigenTrust [already cited as [3]]
│   ├── Power-law distributions in networks
│   └── eBay transaction analysis
│
├── KEY CITING WORKS:
│   ├── METrust (2012) - mutual evaluation
│   ├── Proof of Reputation (2019)
│   └── Mobile P2P trust systems
│
└── OUR PAPER: Correctly cites PowerTrust
```

#### [38] Budish Blockchain Limits - Citation Network
```
Budish (2018/2024) [385 citations]
│
├── BUILDS ON:
│   ├── Bitcoin economics literature
│   ├── Mechanism design
│   └── Security economics
│
├── KEY CITING WORKS:
│   ├── Gans & Gandal (2019) - PoS limits [already cited as [39]]
│   ├── Blockchain scalability research
│   └── Layer 2 economic analysis
│
└── OUR PAPER: Correctly cites; central to economic argument
```

---

## Part 3: Gap Analysis

### Citations We Should Add (Verified Accessible)

1. **Golbeck (2005)** - TidalTrust dissertation
   - Why: Prior art for personalized trust computation
   - Access: [Academia.edu PDF](https://www.academia.edu/155626/)

2. **Richters & Peixoto (2011)** - Trust transitivity
   - Why: Critical finding about absolute trust threshold
   - Access: [PMC Open Access](https://pmc.ncbi.nlm.nih.gov/articles/PMC3071725/)

3. **Friedman & Resnick (2001)** - Cheap pseudonyms
   - Why: Foundational whitewashing analysis
   - Access: Multiple open versions available

4. **SybilLimit (2008)** - Yu et al.
   - Why: Improved bounds over SybilGuard (which we cite)
   - Access: [NUS PDF](https://www.comp.nus.edu.sg/~yuhf/yuh-sybillimit.pdf)

5. **MeritRank (2022)** - Nasrulin & Ishmaev
   - Why: Contemporary work with aligned "bounding" philosophy
   - Access: [arXiv](https://arxiv.org/abs/2207.09950)

6. **Tadelis (2016)** - Reputation review
   - Why: Comprehensive review of feedback systems
   - Access: [Berkeley PDF](https://faculty.haas.berkeley.edu/stadelis/Annual_Review_Tadelis.pdf)

7. **Florian et al. (2022)** - FBA analysis
   - Why: Critical analysis of Stellar-style consensus
   - Access: [arXiv](https://arxiv.org/abs/2002.08101)

8. **BarterCast (2009)** - Meulpolder et al.
   - Why: Prior art for transaction-based trust
   - Access: [ResearchGate](https://www.researchgate.net/publication/228871839)

9. **Ruderman (2005)** - Advogato vulnerability
   - Why: Quadratic attack vulnerability in flow-based trust
   - Access: [squarefree.com](https://www.squarefree.com/2005/05/26/advogato/)

10. **Windrum, Fagiolo & Moneta (2007)** - ABM validation (JASSS)
    - Why: Open access version of ABM validation methodology
    - Access: [JASSS](https://jasss.soc.surrey.ac.uk/10/2/8.html)

### Citations That Would Help But Are Paywalled

| Paper | Why We Want It | Impact If Unavailable |
|-------|---------------|----------------------|
| Personalized EigenTrust (Choi, 2010) | Full PET formalization | Can cite Golbeck instead |
| k-resilient equilibria (Halpern) | Coalition attack theory | General game theory suffices |
| Full Fagiolo (2007) Comp. Econ. | Complete ABM guide | JASSS version available |

---

## Part 4: Citation Quality Assessment

### Well-Cited Foundations (Keep As-Is)
- [3] EigenTrust - 5,813 citations - foundational
- [6] Douceur - 7,567 citations - foundational
- [7] Nakamoto - massive influence - foundational
- [12] PBFT - ~15,000 citations - foundational
- [21] Gentry FHE - ~12,000 citations - foundational

### Good Recent Additions [35-41]
- [35] FIRE - 592 citations - appropriate trust model
- [36] Subjective Logic - 732 citations - appropriate
- [37] PowerTrust - 781 citations - appropriate
- [38] Budish - 385 citations - central to argument
- [39-41] Supporting economics citations - appropriate

### Potential Issues
- [5] Walsh & Sirer (2006) - 149 citations - relatively low impact, could cut if space needed
- Some economics citations [26-34] may be over-inclusive for a practical paper

---

## Part 5: Recommended Citation Updates

### Add (High Priority)
```
[42] J. Golbeck, "Computing and applying trust in web-based social networks,"
     PhD dissertation, University of Maryland, 2005.

[43] O. Richters and T. P. Peixoto, "Trust transitivity in social networks,"
     PLoS ONE, vol. 6, no. 4, e18384, 2011.

[44] E. Friedman and P. Resnick, "The social cost of cheap pseudonyms,"
     J. Economics & Management Strategy, vol. 10, no. 2, pp. 173-199, 2001.

[45] H. Yu, P. B. Gibbons, M. Kaminsky, and F. Xiao, "SybilLimit: A near-optimal
     social network defense against Sybil attacks," IEEE S&P, 2008.

[46] B. Nasrulin and G. Ishmaev, "MeritRank: Sybil tolerant reputation for
     merit-based tokenomics," arXiv:2207.09950, 2022.

[47] S. Tadelis, "Reputation and feedback systems in online platform markets,"
     Annual Review of Economics, vol. 8, pp. 321-340, 2016.
```

### Add (Medium Priority)
```
[48] M. Florian et al., "The sum of its parts: Analysis of federated byzantine
     agreement systems," Distributed Computing, vol. 35, pp. 399-417, 2022.

[49] M. Meulpolder et al., "BarterCast: A practical approach to prevent lazy
     freeriding in P2P networks," HoT-P2P, 2009.
```

### Consider Adding (If Space)
```
[50] J. Ruderman, "The Advogato trust metric is not attack-resistant," 2005.

[51] P. Windrum, G. Fagiolo, and A. Moneta, "Empirical validation of agent-based
     models: Alternatives and prospects," JASSS, vol. 10, no. 2, 2007.
```

---

*Analysis completed January 2026. All recommended citations verified for PDF accessibility.*
