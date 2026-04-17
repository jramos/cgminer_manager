var injectHashrateTable = function(hash_rates_5s, hash_rates_av, error_rates, target) {
  table = $('<table/>');
  thead = $('<thead/>');
  thead.append($('<th/>').text(''));
  thead.append($('<th/>').text('Min'));
  thead.append($('<th/>').text('Avg'));
  thead.append($('<th/>').text('Max'));
  table.append(thead);

  if (hash_rates_5s.length > 0) {
    var sum = 0;
    for (var i = 0; i < hash_rates_5s.length; i++){ sum += hash_rates_5s[i]; }

    min   = 1e9 * Math.min.apply(Math, hash_rates_5s);
    avg   = 1e9 * sum / hash_rates_5s.length;
    max   = 1e9 * Math.max.apply(Math, hash_rates_5s);

    tr = $('<tr/>');
    tr.append($('<td/>').text('5s'));
    tr.append($('<td/>').text(formatHashrate(min)));
    tr.append($('<td/>').text(formatHashrate(avg)));
    tr.append($('<td/>').text(formatHashrate(max)));
    table.append(tr);
  }

  if (hash_rates_av.length > 0) {
    var sum = 0;
    for (var i = 0; i < hash_rates_av.length; i++){ sum += hash_rates_av[i]; }

    min   = 1e9 * Math.min.apply(Math, hash_rates_av);
    avg   = 1e9 * sum / hash_rates_av.length;
    max   = 1e9 * Math.max.apply(Math, hash_rates_av);

    tr = $('<tr/>');
    tr.append($('<td/>').text('Avg'));
    tr.append($('<td/>').text(formatHashrate(min)));
    tr.append($('<td/>').text(formatHashrate(avg)));
    tr.append($('<td/>').text(formatHashrate(max)));
    table.append(tr);
  }

  if (error_rates.length > 0) {
    var sum = 0;
    for (var i = 0; i < error_rates.length; i++){ sum += error_rates[i]; }

    min   = 100 * Math.min.apply(Math, error_rates);
    avg   = 100 * sum / error_rates.length;
    max   = 100 * Math.max.apply(Math, error_rates);

    tr = $('<tr/>');
    tr.append($('<td/>').text('%'));
    tr.append($('<td/>').text(min.toFixed(3)).append('%'));
    tr.append($('<td/>').text(avg.toFixed(3)).append('%'));
    tr.append($('<td/>').text(max.toFixed(3)).append('%'));
    table.append(tr);
  }

  $(target).append(table);
}

var injectTemperatureTable = function(min_temperatures, avg_temperatures, max_temperatures, target) {
  var sum = 0;
  for(var i = 0; i < avg_temperatures.length; i++){ sum += avg_temperatures[i]; }

  min   = Math.min.apply(Math, min_temperatures).toFixed(1);
  avg   = (sum / avg_temperatures.length).toFixed(1);
  max   = Math.max.apply(Math, max_temperatures).toFixed(1);

  table = $('<table/>');
  thead = table.append($('<thead/>'));
  thead.append($('<th/>').text(''));
  thead.append($('<th/>').text('Min'));
  thead.append($('<th/>').text('Avg'));
  thead.append($('<th/>').text('Max'));

  tr = $('<tr/>');
  tr.append($('<td/>').text('C'));
  tr.append($('<td/>').text(min));
  tr.append($('<td/>').text(avg));
  tr.append($('<td/>').text(max));
  table.append(tr);

  tr = $('<tr/>');
  tr.append($('<td/>').text('F'));
  tr.append($('<td/>').text(toFerinheight(min)));
  tr.append($('<td/>').text(toFerinheight(avg)));
  tr.append($('<td/>').text(toFerinheight(max)));
  table.append(tr);

  $(target).append(table);
}

var injectAvailabilityTable = function (availabilities, target) {
  var sum = 0;
  for(var i = 0; i < availabilities.length; i++){ sum += availabilities[i]; }

  min   = Math.min.apply(Math, availabilities);
  avg   = (sum / availabilities.length);
  max   = Math.max.apply(Math, availabilities);

  table = $('<table/>');
  thead = $('<thead/>');
  thead.append($('<th/>').text('Min'));
  thead.append($('<th/>').text('Avg'));
  thead.append($('<th/>').text('Max'));
  table.append(thead);

  tr = $('<tr/>');
  tr.append($('<td/>').text(min.toFixed(2)).append(' %'));
  tr.append($('<td/>').text(avg.toFixed(2)).append(' %'));
  tr.append($('<td/>').text(max.toFixed(2)).append(' %'));
  table.append(tr);

  $(target).append(table);
}