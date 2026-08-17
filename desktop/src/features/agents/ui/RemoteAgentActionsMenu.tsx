import { EllipsisVertical, Pencil } from "lucide-react";

import type { ManagedAgent } from "@/shared/api/types";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/shared/ui/dropdown-menu";

/**
 * Actions for a display-only (remote-harness) agent card. The record is the
 * only local state — there is no persona to duplicate, share, deactivate, or
 * delete — so Edit (the instance-edit dialog) is the entire menu.
 */
export function RemoteAgentActionsMenu({
  agent,
  onEdit,
}: {
  agent: ManagedAgent;
  onEdit: (agent: ManagedAgent) => void;
}) {
  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger asChild>
        <button
          aria-label={`Open actions for ${agent.name}`}
          className="flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          type="button"
        >
          <EllipsisVertical className="h-4 w-4" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="end"
        onCloseAutoFocus={(event) => event.preventDefault()}
      >
        <DropdownMenuItem onClick={() => onEdit(agent)}>
          <Pencil className="h-4 w-4" />
          Edit
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
