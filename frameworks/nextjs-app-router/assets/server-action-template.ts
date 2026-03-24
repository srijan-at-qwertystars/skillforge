"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";

// --- Validation Schema ---
const CreateItemSchema = z.object({
  name: z.string().min(1, "Name is required").max(100, "Name too long"),
  description: z.string().max(500, "Description too long").optional(),
  category: z.enum(["general", "work", "personal"], {
    errorMap: () => ({ message: "Invalid category" }),
  }),
});

// --- Return Type ---
type ActionState = {
  success: boolean;
  message: string;
  errors?: Record<string, string[]>;
  data?: unknown;
};

// --- Server Action: Create Item ---
// Use with: <form action={createItem}> or useActionState(createItem, initialState)
export async function createItem(
  prevState: ActionState | null,
  formData: FormData
): Promise<ActionState> {
  // 1. Parse and validate input
  const raw = {
    name: formData.get("name"),
    description: formData.get("description"),
    category: formData.get("category"),
  };

  const validated = CreateItemSchema.safeParse(raw);

  if (!validated.success) {
    return {
      success: false,
      message: "Validation failed",
      errors: validated.error.flatten().fieldErrors,
    };
  }

  // 2. Auth check (uncomment and adapt)
  // const session = await auth();
  // if (!session?.user?.id) {
  //   return { success: false, message: "Unauthorized" };
  // }

  // 3. Perform mutation
  try {
    // const item = await db.item.create({
    //   data: {
    //     ...validated.data,
    //     userId: session.user.id,
    //   },
    // });

    // Placeholder for demonstration
    const item = { id: "new-id", ...validated.data };
    console.log("Created item:", item);
  } catch (error) {
    console.error("Failed to create item:", error);
    return {
      success: false,
      message: "Failed to create item. Please try again.",
    };
  }

  // 4. Revalidate cached data
  revalidatePath("/items");

  // 5. Option A: Return success state (for useActionState)
  return {
    success: true,
    message: "Item created successfully",
  };

  // 5. Option B: Redirect (uncomment if preferred)
  // redirect("/items");
}

// --- Server Action: Delete Item ---
export async function deleteItem(id: string): Promise<ActionState> {
  // Auth check
  // const session = await auth();
  // if (!session?.user?.id) {
  //   return { success: false, message: "Unauthorized" };
  // }

  try {
    // const item = await db.item.findUnique({ where: { id } });
    // if (!item) return { success: false, message: "Item not found" };
    // if (item.userId !== session.user.id) {
    //   return { success: false, message: "Forbidden" };
    // }
    // await db.item.delete({ where: { id } });

    console.log("Deleted item:", id);
  } catch (error) {
    console.error("Failed to delete item:", error);
    return {
      success: false,
      message: "Failed to delete item",
    };
  }

  revalidatePath("/items");
  return { success: true, message: "Item deleted" };
}

// --- Server Action: Update Item ---
const UpdateItemSchema = CreateItemSchema.partial().extend({
  id: z.string().min(1),
});

export async function updateItem(
  prevState: ActionState | null,
  formData: FormData
): Promise<ActionState> {
  const raw = {
    id: formData.get("id"),
    name: formData.get("name"),
    description: formData.get("description"),
    category: formData.get("category"),
  };

  const validated = UpdateItemSchema.safeParse(raw);

  if (!validated.success) {
    return {
      success: false,
      message: "Validation failed",
      errors: validated.error.flatten().fieldErrors,
    };
  }

  try {
    const { id, ...data } = validated.data;
    // await db.item.update({ where: { id }, data });
    console.log("Updated item:", id, data);
  } catch (error) {
    console.error("Failed to update item:", error);
    return {
      success: false,
      message: "Failed to update item",
    };
  }

  revalidatePath("/items");
  return { success: true, message: "Item updated" };
}
