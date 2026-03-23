# Upload LiveView Example
#
# A complete file upload LiveView with progress tracking, validation,
# preview, cancellation, and error handling.
#
# File: lib/my_app_web/live/upload_live.ex

defmodule MyAppWeb.UploadLive do
  @moduledoc """
  LiveView for file uploads with progress tracking and validation.

  ## Routes

      live "/upload", UploadLive, :index

  ## Features

  - Drag-and-drop file selection
  - Client-side file type and size validation
  - Real-time upload progress bars
  - Image preview before upload
  - Upload cancellation
  - Error handling and display
  - Multiple file support
  """
  use MyAppWeb, :live_view

  @upload_dir "priv/static/uploads"

  @impl true
  def mount(_params, _session, socket) do
    File.mkdir_p!(@upload_dir)

    {:ok,
     socket
     |> assign(:page_title, "File Upload")
     |> assign(:uploaded_files, [])
     |> allow_upload(:photos,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 5,
       max_file_size: 10_000_000,
       # Chunk size for progress granularity (default 64KB)
       chunk_size: 64_000,
       # Auto-upload as soon as files are selected (optional)
       auto_upload: false,
       # For progress updates more often than per-chunk:
       progress: &handle_progress/3
     )}
  end

  # ── Progress Callback ───────────────────────────────────────────────
  # Called on each chunk upload. Use for logging or custom progress behavior.

  defp handle_progress(:photos, entry, socket) do
    if entry.done? do
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ── Events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", _params, socket) do
    # LiveView automatically validates file type and size.
    # This callback is required but can be a no-op for uploads.
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :photos, fn %{path: tmp_path}, entry ->
        # Generate a unique filename to prevent collisions
        filename = "#{entry.uuid}-#{entry.client_name}"
        dest = Path.join(@upload_dir, filename)

        # Copy from temp location to permanent storage
        File.cp!(tmp_path, dest)

        # Return the public URL path
        {:ok, ~p"/uploads/#{filename}"}
      end)

    {:noreply,
     socket
     |> update(:uploaded_files, &(&1 ++ uploaded_files))
     |> put_flash(:info, "#{length(uploaded_files)} file(s) uploaded successfully.")}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photos, ref)}
  end

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <.header>
        <%= @page_title %>
        <:subtitle>Upload up to 5 images (max 10MB each). Accepted: JPG, PNG, GIF, WebP.</:subtitle>
      </.header>

      <form id="upload-form" phx-submit="save" phx-change="validate" class="mt-8 space-y-6">
        <%!-- Drop zone --%>
        <div class="border-2 border-dashed border-gray-300 rounded-lg p-8 text-center
                    hover:border-blue-400 transition-colors"
             phx-drop-target={@uploads.photos.ref}>
          <.live_file_input upload={@uploads.photos} class="hidden" />

          <div class="space-y-2">
            <p class="text-lg text-gray-600">
              Drag & drop files here or
              <label for={@uploads.photos.ref} class="text-blue-500 cursor-pointer hover:underline">
                browse
              </label>
            </p>
            <p class="text-sm text-gray-400">
              <%= length(@uploads.photos.entries) %>/<%= @uploads.photos.max_entries %> files selected
            </p>
          </div>
        </div>

        <%!-- Upload-level errors (e.g., too many files) --%>
        <div :for={err <- upload_errors(@uploads.photos)} class="text-red-500 text-sm">
          <%= upload_error_to_string(err) %>
        </div>

        <%!-- File entries with preview, progress, and cancel --%>
        <div :for={entry <- @uploads.photos.entries} class="flex items-center gap-4 p-4 border rounded-lg">
          <%!-- Image preview --%>
          <.live_img_preview entry={entry} class="w-20 h-20 object-cover rounded" />

          <div class="flex-1 min-w-0">
            <%!-- Filename --%>
            <p class="text-sm font-medium truncate"><%= entry.client_name %></p>

            <%!-- File size --%>
            <p class="text-xs text-gray-500"><%= format_bytes(entry.client_size) %></p>

            <%!-- Progress bar --%>
            <div class="mt-1 w-full bg-gray-200 rounded-full h-2">
              <div class="bg-blue-500 rounded-full h-2 transition-all duration-300"
                   style={"width: #{entry.progress}%"}>
              </div>
            </div>

            <%!-- Per-entry errors --%>
            <p :for={err <- upload_errors(@uploads.photos, entry)} class="text-red-500 text-xs mt-1">
              <%= upload_error_to_string(err) %>
            </p>
          </div>

          <%!-- Cancel button --%>
          <button type="button"
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  class="text-gray-400 hover:text-red-500 text-xl"
                  aria-label="Cancel upload">
            &times;
          </button>
        </div>

        <%!-- Submit --%>
        <.button
          type="submit"
          phx-disable-with="Uploading..."
          disabled={@uploads.photos.entries == []}
          class="w-full"
        >
          Upload <%= length(@uploads.photos.entries) %> file(s)
        </.button>
      </form>

      <%!-- Previously uploaded files --%>
      <div :if={@uploaded_files != []} class="mt-10">
        <h3 class="text-lg font-semibold mb-4">Uploaded Files</h3>
        <div class="grid grid-cols-3 gap-4">
          <div :for={url <- @uploaded_files} class="border rounded-lg overflow-hidden">
            <img src={url} class="w-full h-32 object-cover" />
            <p class="text-xs text-gray-500 p-2 truncate"><%= Path.basename(url) %></p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp upload_error_to_string(:too_large), do: "File is too large (max 10MB)."
  defp upload_error_to_string(:too_many_files), do: "Too many files (max 5)."
  defp upload_error_to_string(:not_accepted), do: "File type not accepted. Use JPG, PNG, GIF, or WebP."
  defp upload_error_to_string(err), do: "Upload error: #{inspect(err)}"
end

# ── External/Cloud Upload Variant ──────────────────────────────────────
#
# For direct-to-S3 uploads, replace `allow_upload` with:
#
#   allow_upload(:photos,
#     accept: ~w(.jpg .jpeg .png),
#     max_entries: 5,
#     max_file_size: 50_000_000,
#     external: &presign_upload/2
#   )
#
#   defp presign_upload(entry, socket) do
#     config = %{
#       region: "us-east-1",
#       bucket: System.get_env("S3_BUCKET"),
#       access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
#       secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY")
#     }
#
#     key = "uploads/#{entry.uuid}-#{entry.client_name}"
#
#     {:ok, presigned_url} =
#       ExAws.Config.new(:s3, config)
#       |> ExAws.S3.presigned_url(:put, config.bucket, key,
#         expires_in: 3600,
#         headers: %{"Content-Type" => entry.client_type}
#       )
#
#     meta = %{
#       uploader: "S3",
#       key: key,
#       url: presigned_url
#     }
#
#     {:ok, meta, socket}
#   end
