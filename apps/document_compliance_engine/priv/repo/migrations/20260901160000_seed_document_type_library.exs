defmodule DocumentComplianceEngine.Repo.Migrations.SeedDocumentTypeLibrary do
  @moduledoc """
  Four more document types — `receipt`, `purchase_order`, `payroll_statement`,
  `bank_details` — taking the registry from two to six. Data only: not one
  line of pipeline code changes to support them, which is the point. Each
  is a real exercise of a different part of the config surface rather than
  four copies of `invoice`:

    - `receipt` — single role, one MCP rule, types on the total and date.
    - `purchase_order` — the mirror image of `invoice` (ordering work not
      yet done vs. billing for work already done), and the first type with
      two `date` fields where the descriptions are what tell them apart.
    - `payroll_statement` — **no `validation_rules` at all.** A type can be
      pure extraction: the automatic checks (grounding, completeness,
      confidence, declared types) still run, and deliberately nothing
      external does. Screening an employee's name against a sanctions
      watchlist would be the wrong thing to do with payroll data, so this
      type is the demonstration that "no rules" is a supported
      configuration and not an unfinished one.
    - `bank_details` — the `format`/`regex` rules earning their keep on
      identifier schemes that are deliberately *not* field types (see
      `Agent.FieldTypes`): `iban` runs a real mod-97 checksum, `bic` a
      document-type-specific pattern. Both fields stay typed `"string"`.

  Written through `repo().query!/2` with bound parameters rather than
  interpolated SQL — the descriptions are prose, and prose in hand-built
  SQL string literals is how a stray apostrophe becomes a migration
  failure.
  """

  use Ecto.Migration

  @types [
    %{
      slug: "receipt",
      name: "Purchase receipt",
      description: """
      A receipt issued at the point of sale, evidencing a payment that has \
      already been made. Names the merchant, the total paid, the date of \
      purchase and how it was paid. Distinguished from an invoice by \
      recording a completed payment rather than requesting one, and from a \
      purchase order by describing goods already handed over.\
      """,
      extraction_schema: %{
        "receipt" => %{
          "merchant_name" => %{
            "type" => "string",
            "description" => "The business that sold the goods and took the payment."
          },
          "total" => %{
            "type" => "monetary_amount",
            "description" =>
              "The final amount actually paid, after any tax and discount — not a subtotal."
          },
          "purchase_date" => %{
            "type" => "date",
            "description" => "The date the purchase was made and paid for."
          },
          "payment_method" => %{
            "type" => "string",
            "description" =>
              "How the payment was made (card, cash, transfer), quoted as the receipt states it."
          }
        }
      },
      validation_rules: [
        %{
          "type" => "mcp_tool",
          "tool" => "screen_vendor",
          "field" => %{"role" => "receipt", "name" => "merchant_name"}
        }
      ],
      shape_signals: %{
        "receipt" => %{
          "keywords" => ["receipt", "total", "subtotal", "paid", "change due", "thank you"],
          "min_matches" => 2
        }
      }
    },
    %{
      slug: "purchase_order",
      name: "Purchase order",
      description: """
      A purchase order issued by a buyer to a supplier, authorising the \
      supply of goods or services that have not yet been delivered. Names \
      both parties, an order reference, the date it was raised, the date \
      delivery is required, and the total value being committed. \
      Distinguished from an invoice by ordering work not yet done rather \
      than requesting payment for work already done.\
      """,
      extraction_schema: %{
        "purchase_order" => %{
          "buyer_name" => %{
            "type" => "string",
            "description" => "The organisation raising the order and committing to pay."
          },
          "supplier_name" => %{
            "type" => "string",
            "description" => "The organisation being ordered from, who will be paid."
          },
          "po_number" => %{"type" => "string"},
          "order_date" => %{
            "type" => "date",
            "description" => "The date the order was raised by the buyer."
          },
          "delivery_date" => %{
            "type" => "date",
            "description" =>
              "The date delivery is required or promised — later than the order date, and " <>
                "not the same thing as it."
          },
          "total" => %{
            "type" => "monetary_amount",
            "description" => "The total value of the order across all line items."
          }
        }
      },
      validation_rules: [
        %{
          "type" => "mcp_tool",
          "tool" => "screen_vendor",
          "field" => %{"role" => "purchase_order", "name" => "supplier_name"}
        }
      ],
      shape_signals: %{
        "purchase_order" => %{
          "keywords" => [
            "purchase order",
            "p.o.",
            "po number",
            "supplier",
            "ship to",
            "order date"
          ],
          "min_matches" => 2
        }
      }
    },
    %{
      slug: "payroll_statement",
      name: "Payroll statement",
      description: """
      A payslip issued by an employer to an employee for one pay period, \
      stating gross earnings and the net amount actually paid. Names the \
      employer, the employee, the period the pay covers, and both figures. \
      Distinguished from an invoice or receipt by concerning employment \
      earnings rather than a sale between businesses.\
      """,
      extraction_schema: %{
        "payroll_statement" => %{
          "employer_name" => %{
            "type" => "string",
            "description" => "The employer paying the wages."
          },
          "employee_name" => %{"type" => "string"},
          "pay_period_end" => %{
            "type" => "date",
            "description" =>
              "The last day of the period this payslip covers — not the date it was issued " <>
                "or paid."
          },
          "gross_pay" => %{
            "type" => "monetary_amount",
            "description" => "Total earnings for the period before any deductions."
          },
          "net_pay" => %{
            "type" => "monetary_amount",
            "description" => "The amount actually paid to the employee after all deductions."
          }
        }
      },
      # Deliberately empty — see the moduledoc.
      validation_rules: [],
      shape_signals: %{
        "payroll_statement" => %{
          "keywords" => [
            "payroll",
            "payslip",
            "pay period",
            "gross pay",
            "net pay",
            "earnings",
            "deductions"
          ],
          "min_matches" => 2
        }
      }
    },
    %{
      slug: "bank_details",
      name: "Vendor bank details",
      description: """
      A bank details form or letter supplied by a vendor so that payments \
      can be routed to their account. Names the account holder, the bank, \
      and the account identifiers themselves. Distinguished from an \
      invoice by requesting no payment for anything in particular — it \
      establishes where money should go, which is exactly why the \
      identifiers on it are worth checking.\
      """,
      extraction_schema: %{
        "bank_details" => %{
          "account_holder" => %{
            "type" => "string",
            "description" =>
              "The legal name the account is held in, which should be the vendor's own."
          },
          "bank_name" => %{"type" => "string"},
          # Identifier schemes stay "string" and are checked by a rule, not
          # a type — see Agent.FieldTypes' moduledoc.
          "iban" => %{
            "type" => "string",
            "description" => "The international bank account number, as printed."
          },
          "bic" => %{
            "type" => "string",
            # Shape is the `regex` rule's business, not the description's —
            # see the descriptions migration on why a description that
            # states a format gets that format invented.
            "description" => "The BIC/SWIFT code identifying the bank, as printed."
          }
        }
      },
      validation_rules: [
        %{
          "type" => "format",
          "validator" => "iban",
          "field" => %{"role" => "bank_details", "name" => "iban"}
        },
        %{
          "type" => "regex",
          "pattern" => "^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$",
          "field" => %{"role" => "bank_details", "name" => "bic"}
        },
        %{
          "type" => "mcp_tool",
          "tool" => "screen_vendor",
          "field" => %{"role" => "bank_details", "name" => "account_holder"}
        }
      ],
      shape_signals: %{
        "bank_details" => %{
          "keywords" => ["iban", "bic", "swift", "account holder", "bank details", "sort code"],
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
          Enum.map(type.validation_rules, & &1),
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
