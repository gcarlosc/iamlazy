# Ground — `--model` flag

- **Fuente de verdad del modelo:** `models.conf`, 4 vars sourceadas por `install.sh:133` →
  `CC_MAIN_MODEL`, `CC_CRITIC_MODEL`, `OC_MAIN_MODEL`, `OC_CRITIC_MODEL` [observed: rg models.conf/install.sh].
- **Cómo se proyecta:** `render()` (`install.sh:38`) hace `sed` de `{{MAIN_MODEL}}`/`{{CRITIC_MODEL}}`
  en cada frontmatter; `install_claude`/`install_opencode` pasan las vars por rol [observed: install.sh:56-91].
- **Parsing de args:** loop `install.sh:95-101`, hoy solo conoce `--tool=` y `-h`; catch-all rechaza
  lo desconocido (`unknown arg`) [observed: install.sh:99]. `TOOL="auto"` por default [observed: install.sh:94].
- **Resolución de herramienta:** `do_claude`/`do_opencode` se calculan en `install.sh:138-152`;
  `auto` puede prender ambas [observed].
- **Portabilidad sed:** install.sh nunca usa `sed -i` (solo `sed -e … archivo`), coherente con macOS
  bash 3.2; la persistencia debe usar `sed → tmp → mv`, no `-i` [observed: claim 2].
- **Namespaces de id incompatibles:** CC toma ids Anthropic pelados, OC toma `provider/model`
  [observed: PROJECT.md:73-77, README:128] → un `--model` sirve para una herramienta por corrida [inferred].
- **Docs afectadas:** `README.md:111-129` (tabla "Models and credentials") y ADR en `PROJECT.md:73` [observed].
- **Remoto vs local:** en `curl|bash`, `SRC` es un temp descartable; persistir ahí es inútil →
  persistir solo en clone+run (`SCRIPT_DIR` no vacío) [observed: install.sh:104-130].
