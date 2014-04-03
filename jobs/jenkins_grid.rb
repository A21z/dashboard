require 'net/http'
require 'json'

url = 'http://hub.ci.cloud.commercetools.de/'

views = {
  grid_base: { name: 'grid-base', prio: 1 },
  grid_solr: { name: 'grid-solr', prio: 2 },
  grid_stores: { name: 'grid-stores', prio: 1 },
  grid_webtests: { name: 'grid-webtests', prio: 2 },
}


# Collect currently building jobs
SCHEDULER.every '5s', :first_in => 0 do
  
  uri      = URI.parse(url)
  http     = Net::HTTP.new(uri.host, uri.port)
  api_url  = url + '/api/json?tree=jobs[name,color,url]'
  response = http.request(Net::HTTP::Get.new(api_url))
  jobs     = JSON.parse(response.body)['jobs']

  # Filter, what we want to see
  jobs_building = jobs.select { |job|
    (job['color'].include? 'anime')
  }
  jobs_building.map! { |job|
    # Retrieve the last build aka the one actually building
    uri        = URI.parse(job['url'])
    http       = Net::HTTP.new(uri.host, uri.port)
    api_url    = job['url'] + 'api/json?tree=lastBuild[url]'
    response   = http.request(Net::HTTP::Get.new(api_url))
    last_build = JSON.parse(response.body)['lastBuild']

    # Retrieve the last build aka the one actually building
    uri                 = URI.parse(last_build['url'])
    http                = Net::HTTP.new(uri.host, uri.port)
    api_url             = last_build['url'] + 'api/json?tree=timestamp'
    response            = http.request(Net::HTTP::Get.new(api_url))
    timestamp           = JSON.parse(response.body)['timestamp']
    api_url             = last_build['url'] + 'api/json?tree=estimatedDuration'
    response            = http.request(Net::HTTP::Get.new(api_url))
    estimated_duration  = JSON.parse(response.body)['estimatedDuration']

    offset = 22 # our lag to ci server

    build_start = (timestamp / 1000)
    elapsed = Time.now.to_i - build_start + offset
    done = (elapsed * 100) / (estimated_duration / 1000)
    left = 100 - done

    { name: trim_job_name(job['name']), state: job['color'], done: done, left: left}
  }

  send_event('jenkins_build', { jobs: jobs_building })
end


# Collect failing jobs
SCHEDULER.every '10s', :first_in => 0 do

  uri      = URI.parse(url)
  http     = Net::HTTP.new(uri.host, uri.port)
  api_url  = url + '/api/json?tree=jobs[name,color]'
  response = http.request(Net::HTTP::Get.new(api_url))
  jobs     = JSON.parse(response.body)['jobs']

  # Filter, what we want to see
  jobs_failed = jobs.select { |job|
    ((job['color'].include? 'red') ||  (job['color'].include? 'yellow')) && (!job['name'].include? 'sphere')
  }
  jobs_failed.map! { |job|
    { name: trim_job_name(job['name']), state: job['color'] }
  }

  send_event('jenkins_jobs_grid_failed', { jobs: jobs_failed })
end


# Collect jobs, that are currently in the queue
SCHEDULER.every '5s', :first_in => 0 do

  uri      = URI.parse(url)
  http     = Net::HTTP.new(uri.host, uri.port)
  api_url  = url + '/queue/api/json?tree=items[inQueueSince,task[name,color]]'
  response = http.request(Net::HTTP::Get.new(api_url))
  items    = JSON.parse(response.body)['items']

  items.sort_by { |item| item['inQueueSince'] }
  items.reverse!
  items.map! { |item|
    { name:  trim_job_name(item['task']['name']), state: item['task']['color'] }
  }

  send_event('jenkins_queue', { items: items })
end


# Collect job group status
SCHEDULER.every '5s', :first_in => 0 do

  views.each do |key, view|
    critical_count = 0
    warning_count  = 0

    uri      = URI.parse(url)
    http     = Net::HTTP.new(uri.host, uri.port)
    api_url  = url + '/view/' + view[:name] + '/api/json?tree=jobs[name,color]'
    response = http.request(Net::HTTP::Get.new(api_url))
    jobs     = JSON.parse(response.body)['jobs']

    jobs.each do |job|
      if job['color'].include? 'red'
        critical_count += 1
      elsif job['color'].include? 'yellow'
        warning_count += 1
      end
    end
    
    status = if critical_count > 0 then
               'danger'
             else
               warning_count > 0 ? 'warning' : 'ok'
             end

    send_event('jenkins_status_view_' + key.to_s, { criticals: critical_count, warnings: warning_count, status: status, prio: view[:prio]})
  end
end


# Trim job names to avoid the long names break the frontend
def trim_job_name(job_name)
  job_name = job_name.gsub('grid-', '');
  job_name = job_name.gsub('store-', '');
  job_name = job_name.gsub('sphere-', '');
  job_name = job_name.gsub('-public-deb', '');
  job_name = job_name.gsub('-private-deb', '');
  job_name = job_name.gsub('solr', 's');
  job_name = job_name.gsub('automation', 'am');
  job_name = job_name.gsub('webtests-production', 'wp');
  job_name = job_name.gsub('webtests-staging', 'ws');
  job_name = job_name.gsub('checkout', 'co');
  job_name = job_name.gsub('saucelabs', 'slabs');
  return job_name
end 