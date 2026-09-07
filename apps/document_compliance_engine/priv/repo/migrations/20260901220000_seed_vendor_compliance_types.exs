defmodule DocumentComplianceEngine.Repo.Migrations.SeedVendorComplianceTypes do
  @moduledoc """
  Three more document types, taking the registry to nine — chosen the same
  way the previous four were: each has to exercise something no existing
  type does, rather than being a fifth flat business document.

    - `certificate_of_insurance` — the first user of the `not_expired`
      rule, added alongside it. A COI that was valid when it was filed and
      has since lapsed is a real compliance finding that no amount of
      reading the document produces, and it is the reason that rule kind
      exists at all.
    - `w8ben` — the W-9's foreign-vendor sibling, and the first user of the
      `vat_id` format validator, which has existed unused since
      `FormatValidators` was written.
    - `business_registration` — the first user of the `email`, `phone` and
      `uri` field types and the `postal_address` validator, all of which
      were part of the vocabulary with nothing declaring them.

  All three are genuine vendor-onboarding compliance documents, which is
  the domain this project is actually about — a COI and a registration
  certificate are things a business really does collect from a new vendor,
  where a bank statement or a driving licence would be breadth borrowed
  from a general document-processing product.

  Descriptions state meaning only, never format — see the descriptions
  migration for the measured reason.
  """

  use Ecto.Migration

  @types [
    %{
      slug: "certificate_of_insurance",
      name: "Certificate of insurance",
      description: """
      A certificate issued by an insurer confirming that a named business \
      holds a policy, for what cover, and over what period. Names the \
      insured business, the insurer, a policy number, the amount of cover \
      and the dates the cover runs between. Distinguished from every other \
      type here by being time-limited: the same document is valid before \
      its expiry date and worthless after it.\
      """,
      extraction_schema: %{
        "certificate_of_insurance" => %{
          "insured_name" => %{
            "type" => "string",
            "description" => "The business the policy covers — the vendor, not the insurer."
          },
          "insurer_name" => %{
            "type" => "string",
            "description" => "The insurance company that issued the certificate."
          },
          "policy_number" => %{"type" => "string"},
          "coverage_amount" => %{
            "type" => "monetary_amount",
            "description" => "The limit of cover the policy provides."
          },
          "effective_date" => %{
            "type" => "date",
            "description" => "The date cover begins."
          },
          "expiry_date" => %{
            "type" => "date",
            "description" =>
              "The date cover ends, after which this certificate no longer evidences anything."
          }
        }
      },
      validation_rules: [
        %{
          "type" => "not_expired",
          "field" => %{"role" => "certificate_of_insurance", "name" => "expiry_date"}
        },
        %{
          "type" => "mcp_tool",
          "tool" => "screen_vendor",
          "field" => %{"role" => "certificate_of_insurance", "name" => "insured_name"}
        }
      ],
      shape_signals: %{
        "certificate_of_insurance" => %{
          "keywords" => [
            "certificate of insurance",
            "policy number",
            "insured",
            "coverage",
            "liability limit",
            "insurer"
          ],
          "min_matches" => 2
        }
      }
    },
    %{
      slug: "w8ben",
      name: "Form W-8BEN-E (foreign vendor)",
      description: """
      A US tax form completed by a business outside the United States to \
      certify foreign status and claim any treaty benefit, filed instead of \
      a Form W-9. States the foreign entity's legal name, its country of \
      residence, its local tax registration number and the date it was \
      signed. Distinguished from a W-9 by the entity being foreign and by \
      carrying a country-prefixed VAT registration rather than a US EIN.\
      """,
      extraction_schema: %{
        "w8ben" => %{
          "entity_name" => %{
            "type" => "string",
            "description" => "The legal name of the foreign entity certifying its status."
          },
          "country_of_residence" => %{
            "type" => "string",
            "description" => "The country whose tax residence the entity is claiming."
          },
          "vat_id" => %{
            "type" => "string",
            "description" =>
              "The entity's local VAT or tax registration number, copied exactly as the form " <>
                "writes it."
          },
          "date_signed" => %{
            "type" => "date",
            "description" => "The date the certification was signed."
          }
        }
      },
      validation_rules: [
        %{
          "type" => "format",
          "validator" => "vat_id",
          "field" => %{"role" => "w8ben", "name" => "vat_id"}
        },
        %{
          "type" => "mcp_tool",
          "tool" => "screen_vendor",
          "field" => %{"role" => "w8ben", "name" => "entity_name"}
        }
      ],
      shape_signals: %{
        "w8ben" => %{
          "keywords" => [
            "w-8ben",
            "foreign status",
            "beneficial owner",
            "country of residence",
            "tax treaty",
            "vat"
          ],
          "min_matches" => 2
        }
      }
    },
    %{
      slug: "business_registration",
      name: "Business registration certificate",
      description: """
      An extract or certificate from a companies registry evidencing that a \
      business is incorporated and in good standing. States the registered \
      legal name, the registration number the registry assigned, the \
      jurisdiction that issued it, the registered address and the contact \
      details on file. Distinguished from a tax form by evidencing \
      existence and standing rather than tax status.\
      """,
      extraction_schema: %{
        "business_registration" => %{
          "legal_name" => %{
            "type" => "string",
            "description" => "The registered legal name, including any suffix the registry lists."
          },
          "registration_number" => %{"type" => "string"},
          "jurisdiction" => %{
            "type" => "string",
            "description" => "The country or state whose registry issued this certificate."
          },
          "registered_address" => %{
            "type" => "string",
            "description" => "The registered office address on file with the registry."
          },
          "contact_email" => %{"type" => "email"},
          "contact_phone" => %{"type" => "phone"},
          "website" => %{"type" => "uri"}
        }
      },
      validation_rules: [
        %{
          "type" => "format",
          "validator" => "postal_address",
          "field" => %{"role" => "business_registration", "name" => "registered_address"}
        },
        %{
          "type" => "mcp_tool",
          "tool" => "screen_vendor",
          "field" => %{"role" => "business_registration", "name" => "legal_name"}
        }
      ],
      shape_signals: %{
        "business_registration" => %{
          "keywords" => [
            "certificate of incorporation",
            "companies registry",
            "registration number",
            "registered office",
            "good standing",
            "incorporated"
          ],
          "min_matches" => 2
        }
      }
    }
  ]

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(@types, fn type ->
      repo().query!(
        """
        INSERT INTO document_types
          (slug, name, description, extraction_schema, validation_rules, shape_signals,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
        """,
        [
          type.slug,
          type.name,
          String.trim(type.description),
          type.extraction_schema,
          type.validation_rules,
          type.shape_signals,
          now
        ]
      )
    end)
  end

  def down do
    repo().query!("DELETE FROM document_types WHERE slug = ANY($1)", [
      Enum.map(@types, & &1.slug)
    ])
  end
end
