"use client";

import type { SoloFormation } from "@/lib/admin-solo-games";
import styles from "./solo-formation-fields.module.css";

export function SoloFormationFields({ value, onChange, disabled = false }: {
  value: SoloFormation;
  onChange: (value: SoloFormation) => void;
  disabled?: boolean;
}) {
  return (
    <fieldset className={styles.fields} disabled={disabled}>
      <legend>Formation per team</legend>
      <div className={styles.row}>
        <label><span>Goalkeepers</span><select aria-label="Goalkeepers per team" value={value.goalkeepersPerSide} disabled><option value={1}>1</option></select></label>
        <label><span>Defenders</span><select aria-label="Defenders per team" value={value.defendersPerSide} onChange={(event) => {
          const defendersPerSide = Number(event.target.value);
          onChange({ goalkeepersPerSide: 1, defendersPerSide, attackersPerSide: 6 - defendersPerSide });
        }}>{[0, 1, 2, 3, 4, 5, 6].map((count) => <option key={count} value={count}>{count}</option>)}</select></label>
        <label><span>Attackers</span><select aria-label="Attackers per team" value={value.attackersPerSide} onChange={(event) => {
          const attackersPerSide = Number(event.target.value);
          onChange({ goalkeepersPerSide: 1, defendersPerSide: 6 - attackersPerSide, attackersPerSide });
        }}>{[0, 1, 2, 3, 4, 5, 6].map((count) => <option key={count} value={count}>{count}</option>)}</select></label>
      </div>
      <p>Seven players per team: one keeper and six outfield players. Changing defenders also updates attackers.</p>
    </fieldset>
  );
}
