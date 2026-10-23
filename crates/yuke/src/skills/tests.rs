use super::*;

fn folder(name: &str) -> PathBuf {
    yuke_testing::folder("skills", name)
}

/// Write the skill `name` in `root` with the text `text` as its `SKILL.md`, and return the path of the file.
fn write(root: &Path, name: &str, text: &str) -> PathBuf {
    std::fs::create_dir_all(root.join(name)).unwrap();
    let location = root.join(name).join("SKILL.md");
    std::fs::write(&location, text).unwrap();
    location
}

fn skill_file(name: &str, description: &str) -> String {
    format!("---\nname: {name}\ndescription: {description}\n---\nThe body.\n")
}

/// The name and the description of each skill of `catalog`.
fn named(catalog: &Catalog) -> Vec<(&str, &str)> {
    catalog
        .skills
        .iter()
        .map(|skill| (skill.name.as_str(), skill.description.as_str()))
        .collect()
}

#[test]
fn an_earlier_folder_hides_a_later_skill_of_the_same_name_and_the_list_is_sorted() {
    let root = folder("order");
    let (workspace, user) = (root.join("workspace"), root.join("user"));
    write(&workspace, "pdf", &skill_file("pdf", "From the workspace."));
    let hidden = write(&user, "pdf", &skill_file("pdf", "From the user."));
    write(&user, "charts", &skill_file("charts", "From the user."));

    let catalog = catalog(&[workspace, user, root.join("missing")]);

    assert_eq!(
        named(&catalog),
        [("charts", "From the user."), ("pdf", "From the workspace.")]
    );
    assert_eq!(
        catalog.warnings,
        [format!(
            "yuke skipped the skill at {}: another skill already holds this name",
            hidden.display()
        )]
    );
}

#[test]
fn a_skill_is_a_direct_folder_with_a_skill_file_and_two_links_to_it_count_once() {
    let root = folder("shape");
    let skills = root.join("skills");
    write(&skills, "pdf", &skill_file("pdf", "Read PDF files."));
    std::fs::create_dir_all(skills.join("notes")).unwrap();
    std::fs::write(skills.join("README.md"), "Not a skill.").unwrap();
    write(&skills.join("deep"), "nested", &skill_file("nested", "Too deep."));
    std::os::unix::fs::symlink(skills.join("pdf"), skills.join("pdf-link")).unwrap();

    let catalog = catalog(&[skills]);

    assert_eq!(named(&catalog), [("pdf", "Read PDF files.")]);
    assert_eq!(catalog.warnings, Vec::<String>::new());
    assert_eq!(catalog.skills[0].location, root.join("skills/pdf/SKILL.md"));
}

#[test]
fn the_frontmatter_takes_plain_quoted_and_block_values() {
    let fields = |text: &str| frontmatter(text).unwrap();

    assert_eq!(
        fields("---\nname: pdf # a comment\ndescription: Fill forms: all of them.\nlicense: MIT\n---\n"),
        Fields {
            name: Some("pdf".to_owned()),
            description: Some("Fill forms: all of them.".to_owned()),
        }
    );
    assert_eq!(
        fields("---\r\ndescription: \"Say \\\"hi\\\"\\tnow \\u00e9\"\r\n---\r\n")
            .description
            .unwrap(),
        "Say \"hi\"\tnow \u{e9}"
    );
    assert_eq!(
        fields("---\ndescription: 'It''s fine'\n---\n").description.unwrap(),
        "It's fine"
    );
    assert_eq!(
        fields("---\ndescription: >\n  Read and\n  fill forms.\n\n  Then save.\nmetadata:\n  a: b\n---\n")
            .description
            .unwrap(),
        "Read and fill forms.\nThen save."
    );
    assert_eq!(
        fields("---\ndescription: |-\n  First line.\n  Second line.\n---\n")
            .description
            .unwrap(),
        "First line.\nSecond line."
    );
}

#[test]
fn a_file_without_a_closed_frontmatter_has_none() {
    assert_eq!(frontmatter("name: pdf\n"), None);
    assert_eq!(frontmatter("---\nname: pdf\n"), None);
}

#[test]
fn each_bad_skill_is_skipped_with_its_reason() {
    let root = folder("bad");
    let skills = root.join("skills");
    let cases = [
        ("bare", "No frontmatter.".to_owned(), "the file has no frontmatter"),
        (
            "silent",
            "---\nname: silent\n---\n".to_owned(),
            "the description is missing",
        ),
        (
            "upper",
            skill_file("Upper", "A skill."),
            "the name 'Upper' has a character other than a-z, 0-9, and -",
        ),
        (
            "dashes",
            skill_file("a--b", "A skill."),
            "the name 'a--b' starts or ends with -, or holds --",
        ),
        (
            "long",
            skill_file("long", &"x".repeat(1025)),
            "the description exceeds 1024 characters",
        ),
        (
            "bell",
            skill_file("bell", "\"Ring \\a\""),
            "the description holds a control character",
        ),
    ];
    let mut expected = Vec::new();
    for (name, text, reason) in &cases {
        let location = write(&skills, name, text);
        expected.push(format!("yuke skipped the skill at {}: {reason}", location.display()));
    }

    let catalog = catalog(&[skills]);

    assert_eq!(catalog.skills, []);
    expected.sort();
    let mut warnings = catalog.warnings;
    warnings.sort();
    assert_eq!(warnings, expected);
}

#[test]
fn a_name_that_differs_from_its_folder_loads_with_a_warning_and_no_name_takes_the_folder_name() {
    let root = folder("names");
    let skills = root.join("skills");
    let twin = write(&skills, "twin", &skill_file("alpha", "A skill."));
    write(&skills, "plain", "---\ndescription: No name.\n---\n");

    let catalog = catalog(&[skills]);

    assert_eq!(named(&catalog), [("alpha", "A skill."), ("plain", "No name.")]);
    assert_eq!(
        catalog.warnings,
        [format!(
            "The skill at {} has the name 'alpha', which is not the name of its folder",
            twin.display()
        )]
    );
}

#[test]
fn a_folder_with_more_than_256_skill_folders_loads_the_first_256_with_a_warning() {
    let root = folder("many");
    let skills = root.join("skills");
    for index in 0..=MAX_PER_ROOT {
        let name = format!("s{index:03}");
        write(&skills, &name, &skill_file(&name, "A skill."));
    }

    let catalog = catalog(std::slice::from_ref(&skills));

    assert_eq!(catalog.skills.len(), MAX_PER_ROOT);
    assert_eq!(catalog.skills.last().unwrap().name, "s255");
    assert_eq!(
        catalog.warnings,
        [format!(
            "yuke loads only the first 256 skill folders of {}: it holds 257",
            skills.display()
        )]
    );
}

#[test]
fn a_file_over_the_size_limit_is_skipped() {
    let root = folder("large");
    let skills = root.join("skills");
    let mut text = skill_file("large", "A skill.");
    text.push_str(&"x".repeat(256 * 1024));
    let location = write(&skills, "large", &text);

    let catalog = catalog(&[skills]);

    assert_eq!(catalog.skills, []);
    assert_eq!(
        catalog.warnings,
        [format!(
            "yuke skipped the skill at {}: the file exceeds 256 KiB",
            location.display()
        )]
    );
}

#[test]
fn a_comment_after_a_quoted_value_and_a_comment_alone_do_not_count() {
    let fields =
        frontmatter("---\nname: \"pdf\" # the name\ndescription: 'It''s here' # a note\nlicense: # none\n---\n");

    assert_eq!(
        fields,
        Some(Fields {
            name: Some("pdf".to_owned()),
            description: Some("It's here".to_owned()),
        })
    );
    assert_eq!(
        frontmatter("---\ndescription: # later\n---\n")
            .unwrap()
            .description
            .unwrap(),
        ""
    );
}

#[test]
fn a_plain_value_on_the_next_lines_folds_into_one_line_also_after_a_byte_order_mark() {
    let fields = frontmatter("\u{feff}---\ndescription:\n  Read and\n  fill forms.\n---\n").unwrap();

    assert_eq!(fields.description.unwrap(), "Read and fill forms.");
}

#[test]
fn a_folded_value_keeps_the_line_breaks_around_a_more_indented_line() {
    let fields = frontmatter("---\ndescription: >-\n  first\n    nested\n  last\n---\n").unwrap();

    assert_eq!(fields.description.unwrap(), "first\n  nested\nlast");
}

#[test]
fn a_broken_link_and_a_folder_that_does_not_open_give_warnings() {
    use std::os::unix::fs::PermissionsExt;

    let root = folder("errors");
    let skills = root.join("skills");
    std::fs::create_dir_all(skills.join("broken")).unwrap();
    std::os::unix::fs::symlink(root.join("missing.md"), skills.join("broken/SKILL.md")).unwrap();
    let closed = write(&skills, "closed", &skill_file("closed", "A skill."));
    std::fs::set_permissions(skills.join("closed"), std::fs::Permissions::from_mode(0o000)).unwrap();

    let catalog = catalog(std::slice::from_ref(&skills));
    std::fs::set_permissions(skills.join("closed"), std::fs::Permissions::from_mode(0o755)).unwrap();

    assert_eq!(catalog.skills, []);
    let mut warnings = catalog.warnings;
    warnings.sort();
    assert_eq!(warnings.len(), 2, "{warnings:?}");
    let broken = skills.join("broken/SKILL.md");
    assert!(warnings[0].starts_with(&format!("yuke skipped the skill at {}: ", broken.display())));
    assert!(warnings[1].starts_with(&format!("yuke skipped the skill at {}: ", closed.display())));
}
