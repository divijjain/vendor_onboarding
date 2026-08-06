from evals.fixtures import FIXTURES


def test_bucket_counts_match_the_documented_split():
    buckets = [f.bucket for f in FIXTURES]
    assert buckets.count("clean") == 10
    assert buckets.count("mismatch") == 5
    assert buckets.count("formatting") == 3
    assert buckets.count("malformed") == 2
    assert len(FIXTURES) == 20


def test_fixture_ids_are_unique():
    ids = [f.id for f in FIXTURES]
    assert len(ids) == len(set(ids))


def test_expected_decision_is_approved_only_for_clean_and_formatting_buckets():
    for f in FIXTURES:
        if f.bucket in ("clean", "formatting"):
            assert f.expected_decision == "approved"
        else:
            assert f.expected_decision == "needs_review"
