defmodule VendorOnboarding.DocumentTypes do
  @moduledoc """
  Public API for the document-type registry: what document types this
  system knows how to accept (`slug`, `name`), and their configured
  extraction/validation shape. `defdelegate` only — no logic here.
  """

  alias VendorOnboarding.DocumentTypes.Repository

  defdelegate get_document_type_by_slug(slug), to: Repository, as: :get_by_slug
  defdelegate list_document_types(), to: Repository, as: :list
  defdelegate create_document_type(attrs), to: Repository, as: :insert
end
