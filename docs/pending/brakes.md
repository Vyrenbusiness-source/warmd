### warmd brake
Records what slowed an agent down in a machine-wide log (`brakes.tsv` in the warmd cache dir): date, project, task, cause, minutes, fix idea. Syntax: `warmd brake "<what>" [minutes] [fix idea]`. `warmd note "BRAKE: <what> | ~<min> | <fix>"` lands there too, once per text. `warmd report` and `warmd finish` print the brake minutes of the running batch in one line.

### warmd brakes
Causes from the brake log grouped by their words (case, digits and punctuation do not split a group) and ranked by total minutes lost, one line each, top 10. Syntax: `warmd brakes [--days N]`.
