import styles from "./loading-skeleton.module.css";

type Layout = "cards" | "rows" | "form" | "match" | "dashboard";

/** One announced loading region; its layout placeholders are purely decorative. */
export function LoadingSkeleton({ label, layout = "cards", fullPage = false }: {
  label: string;
  layout?: Layout;
  fullPage?: boolean;
}) {
  return <div className={`${styles.root} ${fullPage ? styles.fullPage : ""}`} role="status" aria-label={label}>
    <div className={`${styles.layout} ${styles[layout]}`} aria-hidden="true">
      {layout === "dashboard" ? <div className={styles.navigation}><i /><i /><i /><i /><i /></div> : null}
      <div className={styles.content}>
        {layout !== "rows" ? <div className={styles.heading}><i /><i /></div> : null}
        <div className={styles.items}>
          {Array.from({ length: layout === "form" ? 2 : 3 }, (_, index) => <div className={styles.item} key={index}>
            {layout === "rows" ? <i className={styles.avatar} /> : null}
            <div className={styles.lines}><i /><i />{layout === "cards" || layout === "match" || layout === "dashboard" ? <i /> : null}</div>
            {layout === "cards" || layout === "form" ? <i className={styles.control} /> : null}
          </div>)}
        </div>
      </div>
    </div>
  </div>;
}
