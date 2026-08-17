import * as React from "react";
import { toast } from "sonner";

import { useSetManagedAgentAvatarMutation } from "@/features/agents/hooks";
import type { ManagedAgent } from "@/shared/api/types";
import { Button } from "@/shared/ui/button";
import { ChooserDialogContent } from "@/shared/ui/chooser-dialog-content";
import { Dialog } from "@/shared/ui/dialog";
import { AgentCreationPreview } from "./AgentCreationPreview";
import { normalizeAvatarUrlInput } from "./managedAgentAvatar";

/**
 * Avatar-only editor for display-only (relay-hosted) agents.
 *
 * A display-only record exists purely so a remote agent keeps a name and
 * avatar in the Agents tab and mention picker — its real configuration lives
 * wherever it runs, so the full AgentInstanceEditDialog (and its
 * full-configuration validation) is the wrong surface. This dialog exposes
 * exactly the one locally-owned field: the avatar (upload, URL, or emoji,
 * via the same picker agent creation uses), persisted through the
 * avatar-only partial-update command.
 *
 * Commits save immediately (community-icon pattern): every commit moment in
 * AgentCreationPreview — upload success, URL apply, emoji apply, clear —
 * persists via set_managed_agent_avatar; a failed save reverts the preview.
 */
export function DisplayOnlyAvatarDialog({
  agent,
  onOpenChange,
  onUpdated,
  open,
}: {
  agent: ManagedAgent;
  onOpenChange: (open: boolean) => void;
  onUpdated?: (agent: ManagedAgent) => void;
  open: boolean;
}) {
  const [draftUrl, setDraftUrl] = React.useState<string | null>(
    agent.avatarUrl ?? null,
  );
  const [isUploadPending, setIsUploadPending] = React.useState(false);
  const mutation = useSetManagedAgentAvatarMutation();

  // Persistent-mount reset lifecycle, keyed like AgentInstanceEditDialog.
  React.useEffect(() => {
    if (open) {
      setDraftUrl(agent.avatarUrl ?? null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, agent.pubkey]);

  const persist = React.useCallback(
    (rawUrl: string) => {
      const avatarUrl = normalizeAvatarUrlInput(rawUrl);
      const previousUrl = agent.avatarUrl ?? null;
      setDraftUrl(avatarUrl);
      mutation.mutate(
        { avatarUrl, pubkey: agent.pubkey },
        {
          onError: (error) => {
            setDraftUrl(previousUrl);
            toast.error(
              error instanceof Error
                ? error.message
                : "Couldn't update the avatar.",
            );
          },
          onSuccess: (updated) => {
            onUpdated?.(updated);
          },
        },
      );
    },
    [agent.avatarUrl, agent.pubkey, mutation, onUpdated],
  );

  const displayLabel = agent.name;

  return (
    <Dialog onOpenChange={onOpenChange} open={open}>
      <ChooserDialogContent
        className="max-w-sm border-0"
        data-testid="display-only-avatar-dialog"
        title={`Edit ${displayLabel}`}
        footer={
          <div className="flex w-full items-center justify-end">
            <Button
              data-testid="display-only-avatar-dialog-done"
              disabled={isUploadPending || mutation.isPending}
              onClick={() => onOpenChange(false)}
              type="button"
            >
              {mutation.isPending ? "Saving..." : "Done"}
            </Button>
          </div>
        }
      >
        <div className="flex flex-col items-center gap-3 py-2">
          <AgentCreationPreview
            avatarUrl={draftUrl}
            label={displayLabel}
            onClearAvatar={() => setDraftUrl(null)}
            onCommitAvatar={persist}
            onSelectAvatar={setDraftUrl}
            onUploadPendingChange={setIsUploadPending}
          />
          <p className="max-w-[260px] text-center text-xs text-muted-foreground">
            This agent runs remotely. Its configuration lives on the host that
            runs it — only the avatar shown on this device is editable here.
          </p>
        </div>
      </ChooserDialogContent>
    </Dialog>
  );
}
