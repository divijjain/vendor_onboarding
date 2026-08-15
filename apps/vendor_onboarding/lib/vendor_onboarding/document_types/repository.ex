defmodule VendorOnboarding.DocumentTypes.Repository do
  @moduledoc """
  The only module that touches `VendorOnboarding.Repo` for the
  `document_types` table.
  """

  alias VendorOnboarding.Repo
  alias VendorOnboarding.DocumentTypes.Schema.DocumentType

  @spec get_by_slug(String.t()) :: DocumentType.t() | nil
  def get_by_slug(slug) do
    Repo.get_by(DocumentType, slug: slug)
  end

  @spec list() :: [DocumentType.t()]
  def list do
    Repo.all(DocumentType)
  end

  @spec insert(map()) :: {:ok, DocumentType.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %DocumentType{}
    |> DocumentType.changeset(attrs)
    |> Repo.insert()
  end
end
