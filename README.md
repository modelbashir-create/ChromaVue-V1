

Quick summary

ChromaVue explores whether a thin colorimetric skin patch plus a native iOS app can provide stable, low-cost signals related to tissue perfusion/oxygenation (StO₂) with human readable hue shifts and phone read numeric absolute sto2. The system targets flap/graft ischemia monitoring where early detection matters and high-end monitors are not always available.



Methods 

Physical patch
	•	Layer stack: PU (top) / PET (pigment layer) / PU (skin-contact) for durability and biocompatibility exploration.
	•	Spectral design (visible only, iPhone-friendly): narrow-band pigments chosen to measure hemoglobin contrast:
	•	PG7 (≈ 555 nm, green)
	•	PY154 (≈ 590 nm, yellow)
	•	PR122 (≈ ~635 nm, red)
	•	Design Patterns:
  Two types 
	•	Blended field for intuitive, continuous hue shift (patient-facing).
	•	Tiled/checkerboard for robust app sampling and QC (research/clinician-facing).
	•	Optional hidden cue (e.g., “CHECK”) revealed when the hue crosses a safety threshold.
	•	Why visible bands? iPhone sensors are filtered against NIR; the patch spectrally shapes reflected visible light so hemoglobin sensitive bands signal perfusion changes.

⸻

Modeling & design optimization

1) MCX (Monte-Carlo eXtreme) forward light transport

We simulate photon transport through PU–PET–PU + skin to predict how pigment optics and tissue parameters shape the captured signal.
	•	Inputs: skin melanin/hematocrit, dermal thickness, patch geometry, pigment spectra, optical densities (OD), tiling vs blended patterns, distance/tilt.
	•	Outputs: band-wise reflectance at 555/590/635 nm, sensitivity to StO₂, and expected camera space features after the app’s normalization steps.

MCX gives ground truth physics for a large design space, but brute forcing every pigment and geometry combo is impossible with limited resources (unlimited computing budget). That’s where surrogates come in.

2) NVIDIA Modulus (physics-informed surrogate)

We train a surrogate model to emulate the MCX forward mapping:
	•	Goal: predict band reflectance/features from (skin params, layer stack, pigment OD, pattern) quickly, with physics aware regularization of data (basically remove data that does not follow the known physics of sto2 reflectence) 
	•	Use: enables fast sweeps across pigment concentrations, layer thicknesses, and layouts without re-running MCX each time. 

3) NVIDIA Physics NeMo (inverse/design search)

We frame design as an optimization/inverse problem:
	•	Design variables: pigment concentrations/OD, pigment mix ratios, patterning (tile vs blend), layer thickness, optional under-layers (e.g., TiO₂ reflector).
	•	Objective(s): match a target StO₂ response curve:
	•	Monotonic and sensitive across the clinical StO₂ range of interest.
	•	Human-visible hue change for the blended design and stable numeric separability for the tiled design.
	•	Robustness to skin tone, thickness, distance/tilt (penalize designs that are overly sensitive to nuisance factors).
	•	Engine: Physics NeMo drives gradient-based or Bayesian search on top of the Modulus surrogate, with spot MCX re-checks for top candidates.

4) Pigment concentration tuning to hit a desired StO₂ curve

we sweep/optimize:
	•	Per pigment OD (PG7/PY154/PR122) and mix ratios to shape the triplet (555/590/635) response vs StO₂.
	•	Patterning (tile pitch vs blend kernel) to balance human perception and camera feature stability.
	•	Layer thicknesses (PU/PET/PU) and optional under layers (e.g., TiO₂) to boost SNR or linearize response.
For each candidate, we evaluate:
	•	Curve fidelity: error to the target StO₂ transfer curve. 
	•	Sensitivity: d(feature)/d(StO₂) where it matters clinically.
	•	Robustness: variance across skin tones, distances, and angles.
Top designs are then re-simulated in MCX at higher photon counts and promoted to validation.

5) NVIDIA Omniverse (synthetic-to-real validation sandbox)

We place the chosen patch designs into physically based scenes to test capture robustness before human/phantom work:
	•	Scenarios: different OR/ward lighting, device distances/angles, motion blur, iPhone model variations.
	•	Assets: render photoreal patch-on-skin views using the surrogate-predicted appearance; feed these images back through the actual iOS pipeline (QC + normalization) to measure end-to-end stability.
	•	Purpose: cut down on benchtop/human iterations and de-risk UI/capture choices.

⸻

Why this matters for ischemia
	•	Early signal: Colorimetric amplification at hemoglobin-sensitive bands can reveal perfusion changes before overt visual cues.
	•	Low friction: A thin patch + smartphone fits bedside and post-discharge workflows.
	•	Human + machine: Blended designs give patients/caregivers an intuitive “looks off” cue; tiled designs give clinicians quantitative trends and exportable research data.


  The code displayed here is an early prtotype of the phone app it does not use a MVVM architecture,the reflectence model itself has not been added to the software. I might make physical changes to the patch such as using upconversion pigments to turn IR light into visible light or estimate an IR reflectence from the 3 wavelngths. 
  Early MCX simulation show that there is enough signal to noise for the phone sensor to detect change over the desired ranges. Its an ideal problem for ML, many weak signals with predictable physics. 

