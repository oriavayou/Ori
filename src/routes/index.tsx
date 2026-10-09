import { createFileRoute, redirect } from "@tanstack/react-router";

// עמוד הפתיחה והתשלומים הוסרו — הכתובת הראשית פותחת ישר את המחשבון.
export const Route = createFileRoute("/")({
  beforeLoad: () => {
    throw redirect({ to: "/app" });
  },
});
