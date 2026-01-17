# Review Cycle 2: Technical and Text Quality Review

Date: January 2026

## Review Questions

The same 10 technical questions from Cycle 1, plus:

11. What ideas in the paper are not completely clear?
12. What sections or sentences seem overly verbose relative to the points they are getting across?
13. What content is being repeated that shouldn't be, and what points aren't being repeated that deserve more emphasis?
14. What structural changes could improve readability?
15. What hooks or punchy lines would best get the main points across?

## Review Findings

### Technical Questions (1-10)

**Progress from Cycle 1:**
- Citations added: FIRE [35], Subjective Logic [36], PowerTrust [37], Budish [38], Gans & Gandal [39], Seuken & Parkes [40], Jackson [41]
- Scale-free topology added to simulations
- Detection vs prevention clarified in Section 7.6.1
- Section 1.0 "Brief History of Trust Systems" added
- Contributions restructured into "Adapted" vs "Novel"
- Limitations section expanded with Douceur impossibility, compute market struggles, AI demand speculation

**Remaining Issues:**
- Still missing long-con and adaptive attacker simulations
- No confidence intervals in simulation results
- Convergence proof still not provided
- Bootstrap problem still underspecified

### 11. Clarity Issues

- The relationship between "currency weight" and network connectivity could be explained more intuitively
- The distinction between "trust score" and "effective trust" (with age derate) may confuse readers
- Section 7.6 jumps between detection rates, economic stability, and finality latency without clear transitions

### 12. Verbose Sections

- **Section 8.6** (Interoperability): The "vision" paragraph and TCP/UDP analogy add little beyond the preceding content
- **Section 8.7** (Villages): "What Omerta provides" could be one paragraph instead of four bullet points; the AI enablement table repeats points made in prose
- **Section 8.8** (Methodology): Strengths and weaknesses lists could be condensed significantly

### 13. Repetition Issues

**Over-repeated:**
- The "spectrum" metaphor appears in abstract, Section 1.2, Section 8.1, Section 8.4, and conclusion
- The village analogy appears in abstract, Section 8.7, and conclusion
- "Machine intelligence both demands compute and enables trust" stated in multiple places

**Under-emphasized:**
- The key insight that *detection window creates risk even with 100% eventual detection*
- The specific ways Omerta differs from EigenTrust (local vs global, transactions vs ratings)
- The concrete economic numbers from simulations (200% compute increase, -3% DC profit impact)

### 14. Structural Suggestions

- Consider moving Section 1.0 (History) to Section 2 (Related Work) to avoid two history sections
- Section 7 (Simulations) could be reorganized: attack scenarios, then economics, then double-spend
- Section 8 has too many subsections (8.1-8.9); consider consolidating

### 15. Suggested Punch Lines

1. "Trust is the API you pay for but never see—until it fails."
2. "Blockchain solved the Byzantine Generals Problem. Compute markets don't have Byzantine generals—they have landlords and tenants."
3. "The village knew; the internet forgot; we're teaching it to remember."
4. "If you have the key, you ARE the identity—there is no 'stealing,' only 'being.'"
5. "Humans run out of ideas; machines run out of compute."
6. "We don't need zero trust. We need enough trust—earned, local, and proportional to what's at stake."
7. "AI is both the demand and the supply: it hungers for compute and enables the trust systems that make sharing compute work."
8. "Detection is not prevention—but if attacks always lose money, does prevention matter?"
9. "The question isn't whether to trust. It's how much trust, at what cost, for what stakes."
10. "Every blockchain rollback is a confession: social consensus was there all along."

**Placement suggestions:**
- Line 1: End of Section 1.2 (Trust Spectrum)
- Line 2: End of Section 2.3 (Blockchain Limits)
- Line 3: Section 8.7 (Villages)
- Line 4: Section 6.5 (Identity-Bound Access)
- Line 5: Section 7.5 (Machine Intelligence Demand)
- Line 6: Conclusion
